import Foundation
@main struct MainLocaleRunner {
 static func main() throws {
  let path=CommandLine.arguments[1],catalog=try UICatalog(data:Data(contentsOf:URL(fileURLWithPath:path)))
  let cases:[(String,String)] = [
   ("你的个人助理","Your personal assistant"),("开始体验","Get started"),("密码","Password"),
   ("正在本机保存","Saving on this device"),("已保存在本机 · 待发送","Saved on this device · Awaiting send"),
   ("发送","Send"),("模型连接","Model connection"),("重新检查连接","Check connection again"),
   ("搜索对话","Search conversations"),("确认图片处理方式","Review image processing"),
   ("消息","Message"),("发送图片前需要确认本次图片处理方式。","Confirm how this image will be processed before sending it.")]
  for (key,en) in cases {guard catalog.text(key,language:.english)==en,catalog.text(key,language:.chinese)==key else {throw NSError(domain:"LocaleMismatch",code:1)};print("PASS locale "+en)}
  guard catalog.text("版本 {0} ({1})",language:.english,arguments:["0.3.0","15"])=="Version 0.3.0 (15)" else {throw NSError(domain:"LocaleInterpolation",code:2)}
  let user="原文 🐾 {0} e\u{301}"
  guard catalog.text("草稿 · ",language:.english)+user=="Draft · "+user,catalog.text(user,language:.english)==user else {throw NSError(domain:"UserContentChanged",code:3)}
  print("PASS version arguments and exact user Unicode preserved")
  print("PASS 14 main-flow locale assertions; Foundation only")
 }
}
