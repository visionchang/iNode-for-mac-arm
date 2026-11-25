use super::*;
async fn receive(socket: &UdpSocket) -> (Packet, std::net::SocketAddr) {
    let mut b = [0; 4096];
    let (n, peer) = socket.recv_from(&mut b).await.unwrap();
    (portal_packet::decode(&b[..n], KEY).unwrap(), peer)
}
async fn respond(
    socket: &UdpSocket,
    peer: std::net::SocketAddr,
    kind: u8,
    serial: u16,
    attrs: Vec<(u8, Vec<u8>)>,
    error: u8,
) {
    let mut b =
        portal_packet::encode(kind, serial, "127.0.0.1".parse().unwrap(), &attrs, KEY).unwrap();
    b[14] = error;
    b[16..32].fill(0);
    let mut check = b.clone();
    check.extend_from_slice(KEY);
    b[16..32].copy_from_slice(&md5::compute(check).0);
    socket.send_to(&b, peer).await.unwrap();
}
#[tokio::test]
async fn portal_domains_login_heartbeat_and_logout() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let endpoint = server.local_addr().unwrap().to_string();
    let login_server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let response_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let port = login_server.local_addr().unwrap().port();
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        let (p, peer) = receive(&server).await;
        assert_eq!(p.kind, 110);
        let serial = p.serial;
        let server_serial = if serial == 3654 { 3655 } else { 3654 };
        respond(
            &server,
            peer,
            111,
            server_serial,
            vec![
                (60, b"web,portal,".to_vec()),
                (55, vec![1]),
                (97, b"127.0.0.1".to_vec()),
                (98, (port as u32).to_be_bytes().to_vec()),
            ],
            0,
        )
        .await;
        let server = login_server;
        let (p, peer) = receive(&server).await;
        assert_eq!(p.kind, 100);
        assert_eq!(p.serial, serial);
        assert_eq!(p.value(101), Some(b"test-user@web".as_slice()));
        let expected = crate::portal_compat::password("test&password", 1).unwrap();
        assert_eq!(p.value(102), Some(expected.as_slice()));
        assert_eq!(p.value(56), Some([1u8].as_slice()));
        assert_eq!(&p.value(33).unwrap()[..2], &[1, 30]);
        let started = p.value(113).unwrap().to_vec();
        respond(
            &response_socket,
            peer,
            101,
            server_serial.wrapping_add(1),
            vec![
                (100, vec![1; 8]),
                (114, b"normalized-session-name".to_vec()),
                (109, 40u64.to_be_bytes().to_vec()),
                (119, 150u64.to_be_bytes().to_vec()),
                (120, 2u32.to_be_bytes().to_vec()),
            ],
            0,
        )
        .await;
        let (p, _peer) = receive(&server).await;
        assert_eq!(p.kind, 104);
        assert_eq!(p.serial, serial);
        assert_eq!(p.value(113), Some(started.as_slice()));
        assert_eq!(p.value(100), Some([1u8; 8].as_slice()));
        assert_eq!(p.value(114), Some(b"normalized-session-name".as_slice()));
        assert_eq!(p.value(120), Some(2u32.to_be_bytes().as_slice()));
        assert_eq!(p.value(122), Some(0u32.to_be_bytes().as_slice()));
        assert_eq!(p.value(125), Some([99].as_slice()));
        // Drop the first heartbeat: a lost UDP response must not end the session.
        let (p, peer) = receive(&server).await;
        assert_eq!(p.kind, 104);
        respond(
            &server,
            peer,
            105,
            server_serial.wrapping_add(2),
            vec![(125, vec![7]), (109, 20u64.to_be_bytes().to_vec())],
            0,
        )
        .await;
        let (p, peer) = receive(&server).await;
        assert_eq!(p.kind, 104);
        assert_eq!(p.value(125), Some([7].as_slice()));
        respond(&server, peer, 105, server_serial.wrapping_add(3), vec![], 0).await;
        stop.send(()).unwrap();
        let (p, peer) = receive(&server).await;
        assert_eq!(p.kind, 102);
        assert_eq!(p.serial, serial);
        respond(&server, peer, 103, server_serial.wrapping_add(3), vec![], 0).await;
    });
    let mut portal = Portal::discover(&endpoint).await.unwrap();
    assert_eq!(portal.info.domains(), ["web", "portal"]);
    portal
        .login("test-user", "test&password", "web")
        .await
        .unwrap();
    portal.maintain(stopped).await.unwrap();
    portal.logout().await.unwrap();
    task.await.unwrap();
}
#[tokio::test]
async fn rejected_password_is_not_retried() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let endpoint = server.local_addr().unwrap().to_string();
    let task = tokio::spawn(async move {
        let (p, peer) = receive(&server).await;
        respond(&server, peer, 111, p.serial, vec![], 0).await;
        let (p, peer) = receive(&server).await;
        assert_eq!(p.kind, 100);
        respond(
            &server,
            peer,
            101,
            p.serial.wrapping_add(1),
            vec![(
                115,
                encoding_rs::GBK.encode("客户端版本无效").0.into_owned(),
            )],
            1,
        )
        .await;
        let mut bytes = [0; 4096];
        assert!(
            tokio::time::timeout(Duration::from_millis(200), server.recv_from(&mut bytes))
                .await
                .is_err()
        );
    });
    let mut portal = Portal::discover(&endpoint).await.unwrap();
    let result = portal.login("test-user", "wrong-test-password", "").await;
    let error = result.unwrap_err().to_string();
    assert!(error.contains("认证请求被服务器拒绝（错误码 1）"));
    assert!(error.contains("客户端版本校验失败"));
    assert!(!error.contains("请检查账号、密码及域"));
    task.await.unwrap();
}
#[tokio::test]
async fn timeout_identifies_login_phase_and_unrelated_response_type() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let target = match server.local_addr().unwrap() {
        std::net::SocketAddr::V4(v) => v,
        _ => unreachable!(),
    };
    let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let task = tokio::spawn(async move {
        let (_, peer) = receive(&server).await;
        respond(&server, peer, 111, 8, vec![], 0).await;
    });
    let request = portal_packet::encode(100, 7, Ipv4Addr::LOCALHOST, &[], KEY).unwrap();
    let error = exchange(
        &client,
        target,
        &request,
        101,
        7,
        "登录认证",
        Duration::from_millis(100),
    )
    .await
    .unwrap_err()
    .to_string();
    assert!(
        error.contains("登录认证超时")
            && error.contains("请求编号 7")
            && error.contains("类型 111，会话 8"),
        "{error}"
    );
    assert!(!error.contains("请确认已连接单位网络"));
    task.await.unwrap();
}

#[tokio::test]
async fn disabled_heartbeats_stay_online_and_still_receive_forced_logout() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let endpoint = server.local_addr().unwrap().to_string();
    let task = tokio::spawn(async move {
        let (p, peer) = receive(&server).await;
        respond(&server, peer, 111, p.serial, vec![], 0).await;
        let (p, peer) = receive(&server).await;
        respond(
            &server,
            peer,
            101,
            p.serial,
            vec![(109, 0u64.to_be_bytes().to_vec())],
            0,
        )
        .await;
        let mut bytes = [0; 4096];
        assert!(
            tokio::time::timeout(Duration::from_millis(150), server.recv_from(&mut bytes))
                .await
                .is_err()
        );
        respond(&server, peer, 118, p.serial, vec![], 0).await;
    });
    let mut portal = Portal::discover(&endpoint).await.unwrap();
    portal.login("dummy", "password", "").await.unwrap();
    let (_stop, stopped) = tokio::sync::oneshot::channel();
    let error = tokio::time::timeout(Duration::from_secs(2), portal.maintain(stopped))
        .await
        .unwrap()
        .unwrap_err();
    assert!(error.to_string().contains("服务器已通知下线"));
    task.await.unwrap();
}
#[tokio::test]
async fn heartbeat_retries_until_server_timeout_without_reauthenticating() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let endpoint = server.local_addr().unwrap().to_string();
    let task = tokio::spawn(async move {
        let (p, peer) = receive(&server).await;
        respond(&server, peer, 111, p.serial, vec![], 0).await;
        let (p, peer) = receive(&server).await;
        respond(
            &server,
            peer,
            101,
            p.serial,
            vec![
                (109, 20u64.to_be_bytes().to_vec()),
                (119, 100u64.to_be_bytes().to_vec()),
            ],
            0,
        )
        .await;
        let mut bytes = [0; 4096];
        let mut count = 0;
        while let Ok(Ok((n, _))) =
            tokio::time::timeout(Duration::from_millis(200), server.recv_from(&mut bytes)).await
        {
            assert_eq!(portal_packet::decode(&bytes[..n], KEY).unwrap().kind, 104);
            count += 1;
        }
        assert!(count >= 2);
    });
    let mut portal = Portal::discover(&endpoint).await.unwrap();
    portal.login("dummy", "password", "").await.unwrap();
    let (_stop, stopped) = tokio::sync::oneshot::channel();
    let began = std::time::Instant::now();
    let error = tokio::time::timeout(Duration::from_secs(2), portal.maintain(stopped))
        .await
        .unwrap()
        .unwrap_err();
    assert!(error.to_string().contains("在线心跳超时"));
    assert!(began.elapsed() >= Duration::from_millis(80));
    task.await.unwrap();
}
