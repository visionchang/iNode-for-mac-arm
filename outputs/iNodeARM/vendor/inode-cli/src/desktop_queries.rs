use anyhow::{Result,ensure};
use inode_cli::protocol;
use std::time::Duration;
pub async fn domains(gateway:&str)->Result<Vec<String>> {
    let session=crate::desktop_policy::session(gateway,Duration::from_secs(8))?;
    let body=session.request(protocol::endpoint(&session.gateway,"/svpn/index.cgi")?,None,true).await?;
    domain_names(&body)
}
fn domain_names(body:&str)->Result<Vec<String>> {
    ensure!(body.len()<=protocol::MAX_BODY&&!body.contains("<!DOCTYPE")&&!body.contains("<!ENTITY"),"Unsupported domain response");
    let doc=roxmltree::Document::parse(body)?;
    let mut names=Vec::new();
    for domain in doc.descendants().filter(|n|n.has_tag_name("domain")) {
        if let Some(name)=domain.children().find(|n|n.has_tag_name("name")).and_then(|n|n.text()) {
            let name=name.trim();ensure!(name.len()<=256,"Domain name too long");
            if !name.is_empty()&&!names.iter().any(|n|n==name){names.push(name.to_owned());}
        }
    }
    ensure!(names.len()<=256,"Too many domains");Ok(names)
}
#[cfg(test)]mod tests {
 use super::*;
 #[test]fn parses_all_domains_without_hardcoded_names(){assert_eq!(domain_names("<data><domainlist><domain><name>duanxin</name></domain><domain><name>office</name></domain></domainlist></data>").unwrap(),["duanxin","office"]);assert!(domain_names("<!DOCTYPE x><data/>").is_err());}
}
