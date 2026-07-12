import type { Metadata, Viewport } from "next";
import { Geist } from "next/font/google";
import { SiteHeader } from "@/components/SiteHeader";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://opencast.mobile"),
  title: "opencast - A Native Podcast Client",
  description:
    "opencast is a native iPhone and iPad podcast client for RSS subscriptions, streaming playback, local progress, and private sync.",
};

export const viewport: Viewport = {
  themeColor: "#0b0d12",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      dir="ltr"
      className={`${geistSans.variable} dark h-full antialiased`}
      data-scroll-behavior="smooth"
      data-theme="dark"
    >
      <body className="flex min-h-full flex-col bg-background font-sans text-foreground">
        <SiteHeader />
        {children}
      </body>
    </html>
  );
}
