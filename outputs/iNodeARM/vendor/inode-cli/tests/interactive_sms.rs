use inode_cli::protocol::{self, GatewayInfo, Session};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use tokio_rustls::{
    TlsAcceptor,
    rustls::{self, pki_types::PrivatePkcs8KeyDer},
};

async fn exercise(kind: &'static str) {
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let pin = format!("{:x}", Sha256::digest(cert.cert.der()));
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![cert.cert.der().clone()],
            PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der()).into(),
        )
        .unwrap();
    let acceptor = TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = protocol::gateway(&format!(
        "https://localhost:{}",
        listener.local_addr().unwrap().port()
    ))
    .unwrap();
    let task=tokio::spawn(async move {
        for step in 0..2 {
            let (tcp,_)=listener.accept().await.unwrap();
            let mut tls=acceptor.accept(tcp).await.unwrap();
            let mut headers=Vec::new();let mut byte=[0];
            while !headers.ends_with(b"\r\n\r\n") {tls.read_exact(&mut byte).await.unwrap();headers.push(byte[0]);}
            let headers=String::from_utf8(headers).unwrap().to_lowercase();
            let length:usize=headers.lines().find_map(|l|l.strip_prefix("content-length:").map(|v|v.trim().parse().unwrap())).unwrap();
            let mut bytes=vec![0;length];tls.read_exact(&mut bytes).await.unwrap();
            let form:std::collections::HashMap<_,_>=url::form_urlencoded::parse(&bytes).collect();
            let xml=roxmltree::Document::parse(form.get("request").unwrap()).unwrap();
            let get=|name|xml.descendants().find(|n|n.has_tag_name(name)).and_then(|n|n.text()).unwrap_or("");
            assert_eq!(get("username"),"test-user");
            let (response,cookie)=if step==0 {
                assert!(headers.starts_with("post /login "));
                assert_eq!(get("vldCode"),"ABCD");
                assert_eq!(get("supportChallengePwd"),"true");
                (format!("<data><result>Challenge</result><type>{kind}</type><smsDynamicPwdd>xyz</smsDynamicPwdd><intervaltime>60</intervaltime></data>"),"svpnginfo=challenge")
            } else {
                assert!(headers.starts_with("post /challenge "));
                assert!(headers.contains("svpnginfo=challenge"));
                assert_eq!(get("type"),kind);assert_eq!(get("code"),"123456");
                if kind=="SMS-IMC" {assert!(get("password").contains("%C2%B1"));assert!(get("password").contains("xyz"));}
                else {assert_eq!(get("password"),"test%26password");}
                ("<data><result>Success</result></data>".to_owned(),"svpnginfo=authenticated")
            };
            tls.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nSet-Cookie: {cookie}; Path=/; Secure\r\nConnection: close\r\n\r\n{response}",response.len()).as_bytes()).await.unwrap();
            let _=tls.shutdown().await;
        }
    });
    let session=Session::new(base.clone(),None,Some(&pin),Duration::from_secs(5)).unwrap();
    let info=GatewayInfo{login:base.join("/login").unwrap(),logout:None,extra_auth:true,auth_parameters:vec![],challenge:Some(base.join("/challenge").unwrap()),captcha:Some(base.join("/captcha").unwrap())};
    let reply=session.authenticate_step(&info,"test-user","test&password",Some("ABCD"),None).await.unwrap();
    assert_eq!(reply.kind,kind);assert_eq!(reply.dynamic,"xyz");
    let reply=session.authenticate_step(&info,"test-user","test&password",None,Some((&reply.kind,"123456",&reply.dynamic))).await.unwrap();
    assert_eq!(reply.result,"Success");
    tokio::time::timeout(Duration::from_secs(5),task).await.unwrap().unwrap();
}
#[tokio::test] async fn sms_gateway_preserves_challenge_cookie(){exercise("SMS-GW").await;}
#[tokio::test] async fn sms_imc_combines_password_challenge_and_code(){exercise("SMS-IMC").await;}
