use super::*;
use anyhow::{Result, ensure};
use zeroize::Zeroizing;

#[derive(Debug, Clone)]
pub struct AuthReply {
    pub result: String, pub kind: String, pub dynamic: String,
    pub message: String, pub interval: u64,
}
impl AuthReply {
    pub fn parse(body: &str) -> Result<Self> {
        let doc = super::discovery::xml(body)?;
        let field = |names: &[&str]| doc.descendants()
            .find(|n| names.iter().any(|s| n.has_tag_name(*s)))
            .and_then(|n| n.text()).unwrap_or("").trim().to_owned();
        let result = field(&["result"]);
        ensure!(!result.is_empty(), "网关返回了无法识别的认证结果");
        Ok(Self { result, kind: field(&["type"]),
            dynamic: field(&["dynamicPwd", "smsDynamicPwdd"]),
            message: field(&["message", "errorMsg", "replyMessage"]),
            interval: field(&["intervaltime", "IntervalTime"]).parse().unwrap_or(60) })
    }
}
fn escape(v: &str) -> String {
    v.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
        .replace('"', "&quot;").replace('\'', "&apos;")
}
fn native_encode(v: &str) -> String {
    v.bytes().map(|b| match b {
        b'A'..=b'Z'|b'a'..=b'z'|b'0'..=b'9' => (b as char).to_string(),
        b' ' => "+".into(), _ => format!("%{b:02X}")
    }).collect()
}
// Mirrors gateway login.js's String.fromCharCode TLV representation.
pub fn imc_password(password: &str, dynamic: &str, code: &str) -> Result<Zeroizing<String>> {
    let mut out = Zeroizing::new(String::new());
    for (tag,value) in [(0xb1,password),(0xb2,dynamic),(0xb3,code)] {
        let len = value.encode_utf16().count();
        ensure!(len <= 253, "短信认证字段过长");
        out.push(char::from_u32(tag).unwrap());
        out.push(char::from_u32((len + 2) as u32).unwrap()); out.push_str(value);
    }
    Ok(out)
}
pub fn challenge_body(user: &str, password: &str, kind: &str, code: &str, dynamic: &str, client: &ClientInfo) -> Result<String> {
    ensure!(["SMS","SMS-GW","SMS-IMC"].contains(&kind), "暂不支持该二次认证类型");
    let pwd = if kind == "SMS-IMC" { imc_password(password,dynamic,code)? }
        else { Zeroizing::new(password.to_owned()) };
    let xml = Zeroizing::new(format!(
        "<data><username>{}</username><password>{}</password><type>{}</type><code>{}</code><language>CN</language><OS>{}</OS><macAddress>{}</macAddress><private>{}</private></data>\r\n",
        escape(user), escape(&native_encode(&pwd)), kind, escape(code), escape(client.os), escape(&client.mac), super::version::client_private()));
    Ok(url::form_urlencoded::Serializer::new(String::new()).append_pair("request", &xml).finish())
}
impl Session {
    pub async fn authenticate_step(&self, info: &GatewayInfo, user: &str, password: &str, captcha: Option<&str>, sms: Option<(&str,&str,&str)>) -> Result<AuthReply> {
        let client = ClientInfo::local(&self.gateway).await?;
        let (url, body) = if let Some((kind,code,dynamic)) = sms {
            (info.challenge.clone().ok_or_else(|| anyhow::anyhow!("网关未提供二次认证接口"))?,
             challenge_body(user,password,kind,code,dynamic,&client)?)
        } else { (info.login.clone(), login_body_with_client(user,password,captcha,Some(&client))) };
        let body = Zeroizing::new(body);
        let response = self.request(url,Some(body.to_string()),false).await?;
        AuthReply::parse(&response)
    }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn parses_sms_challenge() {
        let r=AuthReply::parse("<data><result>Challenge</result><type>SMS-GW</type><intervaltime>90</intervaltime></data>").unwrap();
        assert_eq!(r.kind,"SMS-GW");assert_eq!(r.interval,90);
        assert!(AuthReply::parse("<html/>").is_err());
    }
    #[test] fn imc_utf16_and_form_encoding() {
        assert_eq!(&*imc_password("abc","xy","12").unwrap(),"\u{b1}\u{5}abc\u{b2}\u{4}xy\u{b3}\u{4}12");
        let client=ClientInfo{os:"MacOS",mac:String::new()};
        let b=challenge_body("a<&", "p&", "SMS-GW", "1234", "", &client).unwrap();
        let pairs:Vec<_>=url::form_urlencoded::parse(b.as_bytes()).collect();
        let xml=&pairs[0].1;
        assert!(xml.contains("a&lt;&amp;"));assert!(xml.contains("p%26"));
        assert!(challenge_body("a","b","UNKNOWN","c","",&client).is_err());
    }
}
