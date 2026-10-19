//! Retain a close handle through PassthroughTls's socket replacement. worker's
//! Socket has no Drop-close implementation: dropping a Rust future alone is not
//! sufficient to close its JS TCP socket.
use futures_util::{
    future::{ready, Ready},
    FutureExt,
};
use std::{
    cell::RefCell,
    io,
    pin::Pin,
    rc::Rc,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_postgres::tls::{ChannelBinding, TlsConnect, TlsStream};
use worker::{
    postgres_tls::{PassthroughTls, PassthroughTlsError},
    Socket,
};

#[derive(Clone)]
pub struct OwnedSocket(Rc<RefCell<Option<Socket>>>);
pub struct CloseGuard(OwnedSocket);

impl OwnedSocket {
    pub fn new(socket: Socket) -> (Self, CloseGuard) {
        let stream = Self(Rc::new(RefCell::new(Some(socket))));
        (stream.clone(), CloseGuard(stream))
    }
}

impl CloseGuard {
    pub async fn close(&self) -> worker::Result<()> {
        // Take before awaiting: never hold a RefCell borrow across suspension.
        let socket = self.0 .0.borrow_mut().take();
        if let Some(mut socket) = socket {
            socket.close().await?;
        }
        Ok(())
    }
}

impl Drop for CloseGuard {
    fn drop(&mut self) {
        if let Some(mut socket) = self.0 .0.borrow_mut().take() {
            // Poll once to synchronously call JS Socket.close(). Its promise may
            // remain pending; async Drop cannot await it. Normal exit awaits close
            // with a bound. Server statement/idle deadlines backstop isolate death.
            let _ = socket.close().now_or_never();
        }
    }
}

fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "pilot socket closed")
}

impl AsyncRead for OwnedSocket {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.0.borrow_mut().as_mut() {
            Some(socket) => Pin::new(socket).poll_read(cx, buf),
            None => Poll::Ready(Err(closed())),
        }
    }
}

impl AsyncWrite for OwnedSocket {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.0.borrow_mut().as_mut() {
            Some(socket) => Pin::new(socket).poll_write(cx, bytes),
            None => Poll::Ready(Err(closed())),
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.0.borrow_mut().as_mut() {
            Some(socket) => Pin::new(socket).poll_flush(cx),
            None => Poll::Ready(Err(closed())),
        }
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.0.borrow_mut().as_mut() {
            Some(socket) => Pin::new(socket).poll_shutdown(cx),
            None => Poll::Ready(Err(closed())),
        }
    }
}

pub struct OwnedTls;
impl TlsConnect<OwnedSocket> for OwnedTls {
    type Stream = OwnedSocket;
    type Error = PassthroughTlsError;
    type Future = Ready<Result<Self::Stream, Self::Error>>;
    fn connect(self, stream: OwnedSocket) -> Self::Future {
        let socket = stream
            .0
            .borrow_mut()
            .take()
            .expect("TLS owns an open socket");
        // Pinned worker 0.8.7 returns Ready, and performs start_tls synchronously.
        let result = PassthroughTls
            .connect(socket)
            .now_or_never()
            .expect("PassthroughTls is Ready");
        ready(result.map(|upgraded| {
            *stream.0.borrow_mut() = Some(upgraded);
            stream
        }))
    }
}
impl TlsStream for OwnedSocket {
    fn channel_binding(&self) -> ChannelBinding {
        ChannelBinding::none()
    }
}
