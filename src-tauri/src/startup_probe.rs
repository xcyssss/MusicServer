//! Bounded identity reads from candidate local services. A foreign listener must
//! not extend desktop startup indefinitely by trickling bytes or never closing.
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::{Duration, Instant};

const MAX_RESPONSE_BYTES: usize = 1024 * 1024;

pub fn contains(port: u16, path: &str, marker: &str, deadline: Instant) -> bool {
    probe(port, path, marker, deadline).unwrap_or(false)
}

fn remaining(deadline: Instant) -> std::io::Result<Duration> {
    let time = deadline.saturating_duration_since(Instant::now());
    if time.is_zero() {
        Err(std::io::ErrorKind::TimedOut.into())
    } else {
        Ok(time)
    }
}

fn probe(port: u16, path: &str, marker: &str, deadline: Instant) -> std::io::Result<bool> {
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(
        &address,
        remaining(deadline)?.min(Duration::from_millis(400)),
    )?;
    let request =
        format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    let mut unsent = request.as_bytes();
    while !unsent.is_empty() {
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        let count = stream.write(unsent)?;
        if count == 0 {
            return Ok(false);
        }
        unsent = &unsent[count..];
    }
    let mut response = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        stream.set_read_timeout(Some(remaining(deadline)?))?;
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        if response.len() + count > MAX_RESPONSE_BYTES {
            return Ok(false);
        }
        response.extend_from_slice(&buffer[..count]);
    }
    // Do not accept an error response or a marker echoed only in HTTP headers.
    let Some(boundary) = response.windows(4).position(|bytes| bytes == b"\r\n\r\n") else {
        return Ok(false);
    };
    let headers = String::from_utf8_lossy(&response[..boundary]);
    let mut status = headers
        .lines()
        .next()
        .unwrap_or_default()
        .split_whitespace();
    if !matches!(status.next(), Some("HTTP/1.0" | "HTTP/1.1")) || status.next() != Some("200") {
        return Ok(false);
    }
    let body = &response[boundary + 4..];
    for line in headers.lines().skip(1) {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length")
                && value.trim().parse::<usize>().ok() != Some(body.len())
            {
                return Ok(false);
            }
        }
    }
    Ok(!marker.is_empty() && String::from_utf8_lossy(body).contains(marker))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    fn server(send: impl FnOnce(TcpStream) + Send + 'static) -> (u16, thread::JoinHandle<()>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                if stream.read(&mut byte).unwrap_or(0) == 0 {
                    return;
                }
                request.push(byte[0]);
            }
            send(stream);
        });
        (port, handle)
    }

    #[test]
    fn accepts_split_current_body_and_rejects_stale_or_error_responses() {
        for (response, expected) in [
            ("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\ncurrent", true),
            ("HTTP/1.1 200 OK\r\n\r\nold", false),
            ("HTTP/1.1 503 Busy\r\n\r\ncurrent", false),
            ("HTTP/1.1 200 OK\r\nX-Marker: current\r\n\r\nold", false),
            (
                "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\ncurrent",
                false,
            ),
        ] {
            let (port, handle) = server(move |mut stream| {
                for chunk in response.as_bytes().chunks(3) {
                    let _ = stream.write_all(chunk);
                }
            });
            assert_eq!(
                contains(
                    port,
                    "/health",
                    "current",
                    Instant::now() + Duration::from_secs(2)
                ),
                expected
            );
            handle.join().unwrap();
        }
    }

    #[test]
    fn slow_trickle_cannot_reset_the_total_deadline() {
        let (port, handle) = server(|mut stream| {
            for _ in 0..100 {
                if stream.write_all(b"x").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        assert!(!contains(
            port,
            "/health",
            "current",
            start + Duration::from_millis(150)
        ));
        assert!(start.elapsed() < Duration::from_secs(1));
        handle.join().unwrap();
    }

    #[test]
    fn a_marker_without_connection_completion_is_not_accepted_after_timeout() {
        let (port, handle) = server(|mut stream| {
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\n\r\ncurrent");
            // Hold the response open until the deadline closes the client.
            let mut byte = [0];
            let _ = stream.read(&mut byte);
        });
        assert!(!contains(
            port,
            "/health",
            "current",
            Instant::now() + Duration::from_millis(150)
        ));
        handle.join().unwrap();
    }

    #[test]
    fn oversized_response_is_rejected_even_with_a_current_marker() {
        let (port, handle) = server(|mut stream| {
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\n\r\ncurrent");
            let _ = stream.write_all(&vec![b'x'; MAX_RESPONSE_BYTES]);
        });
        assert!(!contains(
            port,
            "/app.js",
            "current",
            Instant::now() + Duration::from_secs(2)
        ));
        handle.join().unwrap();
    }

    #[test]
    fn expired_budget_does_not_connect() {
        assert!(!contains(0, "/health", "current", Instant::now()));
    }
}
