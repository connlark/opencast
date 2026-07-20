//! Minimal SigV4 query presigner for R2's S3 API (`UploadPart` PUT URLs).
//! The R2 signing credential is a narrow server secret and never enters the
//! app; presigned URLs are bearer credentials with bounded expiry. Region is
//! always "auto" for R2. No general AWS SDK — this is the small native
//! helper the parent plan allows.

use sha2::{Digest, Sha256};

type HmacSha256 = hmac::Hmac<Sha256>;

pub struct PresignRequest<'a> {
    pub method: &'a str,
    pub host: &'a str,
    /// Path with a leading slash; segments are URI-encoded here.
    pub path: &'a str,
    /// Extra query parameters (name, value) — raw, encoded here.
    pub query: &'a [(&'a str, &'a str)],
    pub access_key_id: &'a str,
    pub secret_access_key: &'a str,
    pub region: &'a str,
    /// Seconds since the Unix epoch of signing time.
    pub timestamp: i64,
    pub expires_seconds: u32,
}

pub fn presign_url(request: &PresignRequest<'_>) -> String {
    let (date, datetime) = amz_date(request.timestamp);
    let credential_scope = format!("{date}/{}/s3/aws4_request", request.region);
    let credential = format!("{}/{credential_scope}", request.access_key_id);

    let mut query: Vec<(String, String)> = vec![
        ("X-Amz-Algorithm".into(), "AWS4-HMAC-SHA256".into()),
        ("X-Amz-Credential".into(), credential),
        ("X-Amz-Date".into(), datetime.clone()),
        ("X-Amz-Expires".into(), request.expires_seconds.to_string()),
        ("X-Amz-SignedHeaders".into(), "host".into()),
    ];
    for (name, value) in request.query {
        query.push(((*name).to_string(), (*value).to_string()));
    }
    let mut encoded: Vec<(String, String)> = query
        .iter()
        .map(|(name, value)| (uri_encode(name, true), uri_encode(value, true)))
        .collect();
    encoded.sort();
    let canonical_query = encoded
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("&");

    let canonical_path = encode_path(request.path);
    let canonical_request = format!(
        "{}\n{}\n{}\nhost:{}\n\nhost\nUNSIGNED-PAYLOAD",
        request.method, canonical_path, canonical_query, request.host
    );
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{}\n{}\n{}",
        datetime,
        credential_scope,
        hex::encode(Sha256::digest(canonical_request.as_bytes()))
    );

    let signature = hex::encode(signing_key(
        request.secret_access_key,
        &date,
        request.region,
        &string_to_sign,
    ));

    format!(
        "https://{}{}?{}&X-Amz-Signature={}",
        request.host, canonical_path, canonical_query, signature
    )
}

fn signing_key(secret: &str, date: &str, region: &str, string_to_sign: &str) -> Vec<u8> {
    let k_date = hmac_sha256(format!("AWS4{secret}").as_bytes(), date.as_bytes());
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, b"s3");
    let k_signing = hmac_sha256(&k_service, b"aws4_request");
    hmac_sha256(&k_signing, string_to_sign.as_bytes())
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> Vec<u8> {
    use hmac::Mac;
    let mut mac = <HmacSha256 as hmac::Mac>::new_from_slice(key).expect("hmac accepts any key size");
    mac.update(message);
    mac.finalize().into_bytes().to_vec()
}

fn amz_date(timestamp: i64) -> (String, String) {
    let iso = crate::job::iso8601(timestamp);
    // iso is YYYY-MM-DDTHH:MM:SSZ.
    let date = iso[..10].replace('-', "");
    let time = iso[11..19].replace(':', "");
    (date.clone(), format!("{date}T{time}Z"))
}

fn encode_path(path: &str) -> String {
    path.split('/')
        .map(|segment| uri_encode(segment, false))
        .collect::<Vec<_>>()
        .join("/")
}

/// AWS URI encoding: unreserved characters pass through; everything else is
/// percent-encoded (including '+', with '/' encoded only in query values).
fn uri_encode(value: &str, encode_slash: bool) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char);
            }
            b'/' if !encode_slash => encoded.push('/'),
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AWS's documented presigned-URL example (SigV4 query auth for GET
    /// examplebucket/test.txt, us-east-1, 20130524T000000Z, 86400s).
    #[test]
    fn reproduces_aws_documented_example_signature() {
        let url = presign_url(&PresignRequest {
            method: "GET",
            host: "examplebucket.s3.amazonaws.com",
            path: "/test.txt",
            query: &[],
            access_key_id: "AKIAIOSFODNN7EXAMPLE",
            secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            timestamp: 1_369_353_600, // 2013-05-24T00:00:00Z
            expires_seconds: 86_400,
        });
        assert!(url.contains(
            "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        ), "unexpected URL: {url}");
    }

    #[test]
    fn encodes_upload_id_and_part_number_query() {
        let url = presign_url(&PresignRequest {
            method: "PUT",
            host: "account.r2.cloudflarestorage.com",
            path: "/bucket/uploads/probe-1/source",
            query: &[("partNumber", "2"), ("uploadId", "abc+def/123==")],
            access_key_id: "key",
            secret_access_key: "secret",
            region: "auto",
            timestamp: 1_784_200_000,
            expires_seconds: 900,
        });
        assert!(url.contains("partNumber=2"));
        assert!(url.contains("uploadId=abc%2Bdef%2F123%3D%3D"));
        assert!(url.starts_with("https://account.r2.cloudflarestorage.com/bucket/uploads/probe-1/source?"));
    }
}
