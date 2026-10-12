import Foundation
@main struct ImageReadinessRunner {
 static func main() throws {
  let cases:[(String,String,Bool,String)] = [
   ("nested live v2",#"{"ready":true,"chat_capabilities":{"image_input":true,"vision_contract":{"schema_version":2,"available":true,"state":"live_configured"}}}"#,true,"live_configured"),
   ("nested disabled current shape",#"{"ready":true,"chat_capabilities":{"image_input":false,"vision_contract":{"schema_version":2,"available":false,"state":"disabled"}}}"#,false,"disabled"),
   ("root-only does not authorize",#"{"ready":true,"vision_contract":{"schema_version":2,"available":true},"chat_capabilities":{"image_input":true}}"#,false,"disabled"),
   ("unsupported schema",#"{"ready":true,"chat_capabilities":{"image_input":true,"vision_contract":{"schema_version":3,"available":true,"state":"future_contract"}}}"#,false,"future_contract"),
   ("image input false blocks",#"{"ready":true,"chat_capabilities":{"image_input":false,"vision_contract":{"schema_version":2,"available":true,"state":"live_configured"}}}"#,false,"live_configured"),
   ("unready blocks",#"{"ready":false,"chat_capabilities":{"image_input":true,"vision_contract":{"schema_version":2,"available":true,"state":"live_configured"}}}"#,false,"live_configured"),
   ("text-only legacy response",#"{"ready":true,"chat_capabilities":{"text_input":true}}"#,false,"disabled")]
  for (name,json,available,state) in cases {let value=try ConversationImageReadiness.decode(Data(json.utf8));guard value.available==available,value.state==state else {throw NSError(domain:"ReadinessMismatch",code:1)};print("PASS "+name)}
  do {_ = try ConversationImageReadiness.decode(Data(#"{"ready":true,"chat_capabilities":{"image_input":1,"vision_contract":{"schema_version":2,"available":true}}}"#.utf8));throw NSError(domain:"ExpectedMalformedBoolRejection",code:2)}catch is DecodingError {print("PASS malformed boolean rejected")}
  print("PASS 8 readiness contract assertions; Foundation synthetic only")
 }
}
