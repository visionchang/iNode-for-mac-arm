use serde::Deserialize;
use std::sync::OnceLock;
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
pub struct Policy {pub default_gateway:String,pub default_domain:String,pub server_certificate_policy:String}
pub fn policy()-> &'static Policy {
    static VALUE:OnceLock<Policy>=OnceLock::new();
    VALUE.get_or_init(|| {
        let value:Policy=serde_json::from_str(include_str!("../../../GatewayPolicy.json")).expect("Invalid compiled gateway policy");
        inode_cli::protocol::gateway(&value.default_gateway).expect("Invalid default gateway");
        assert_eq!(value.server_certificate_policy,"windows-compatible","Invalid desktop certificate policy");
        assert!(!value.default_domain.is_empty());
        value
    })
}
pub fn session(gateway:&str,timeout:std::time::Duration)->anyhow::Result<inode_cli::protocol::Session> {
    policy();
    inode_cli::protocol::Session::new_compatible(inode_cli::protocol::gateway(gateway)?,timeout)
}
