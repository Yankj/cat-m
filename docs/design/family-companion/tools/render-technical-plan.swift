import Foundation
import AppKit
import CoreText
import PDFKit

let source = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
let raw = try String(contentsOfFile: source, encoding: .utf8)
let W:CGFloat = 595.28, H:CGFloat = 841.89, M:CGFloat = 42
var media = CGRect(x:0,y:0,width:W,height:H)
let ctx = CGContext(URL(fileURLWithPath:output) as CFURL, mediaBox:&media, nil)!
let ink = NSColor(srgbRed:0.16,green:0.15,blue:0.13,alpha:1)
let orange = NSColor(srgbRed:0.78,green:0.29,blue:0.04,alpha:1)
let blue = NSColor(srgbRed:0.21,green:0.40,blue:0.93,alpha:1)
let gray = NSColor(srgbRed:0.43,green:0.42,blue:0.40,alpha:1)
var y:CGFloat = H-M, page=0
func clean(_ s:String)->String {s.replacingOccurrences(of:"**",with:"").replacingOccurrences(of:"`",with:"")}
func attrs(_ size:CGFloat,_ weight:NSFont.Weight = .regular,_ color:NSColor = ink)->[NSAttributedString.Key:Any] {
 let p=NSMutableParagraphStyle();p.lineSpacing=3;p.lineBreakMode = .byWordWrapping
 return [.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color,.paragraphStyle:p]
}
func text(_ s:String,_ x:CGFloat,_ top:CGFloat,_ w:CGFloat,_ h:CGFloat,_ size:CGFloat=10.5,_ weight:NSFont.Weight = .regular,_ color:NSColor = ink) {
 let a=NSAttributedString(string:s,attributes:attrs(size,weight,color))
 let fs=CTFramesetterCreateWithAttributedString(a);let path=CGPath(rect:CGRect(x:x,y:top-h,width:w,height:h),transform:nil)
 CTFrameDraw(CTFramesetterCreateFrame(fs,CFRange(location:0,length:0),path,nil),ctx)
}
func newPage() {
 if page>0 {ctx.endPDFPage()};ctx.beginPDFPage(nil);page += 1;y=H-M
 ctx.setFillColor(NSColor(srgbRed:1,green:0.988,blue:0.973,alpha:1).cgColor);ctx.fill(media)
 text("cat  /  家庭陪伴场景技术方案",M,H-18,W-2*M,16,8,.medium,gray)
 text("2026-10-22   ·   提案 / 非实施验收",M,27,400,15,8,.regular,gray)
 text(String(page),W-M-35,27,35,15,8,.regular,gray)
}
func para(_ s:String,_ size:CGFloat=10.5,_ weight:NSFont.Weight = .regular,_ color:NSColor=ink,_ after:CGFloat=8) {
 let a=NSAttributedString(string:clean(s),attributes:attrs(size,weight,color));let fs=CTFramesetterCreateWithAttributedString(a)
 var pos=0
 while pos<a.length {
  if y<80 {newPage()}
  let available=y-48
  let path=CGPath(rect:CGRect(x:M,y:48,width:W-2*M,height:available),transform:nil)
  let frame=CTFramesetterCreateFrame(fs,CFRange(location:pos,length:a.length-pos),path,nil)
  let vis=CTFrameGetVisibleStringRange(frame)
  if vis.length==0 {newPage();continue}
  let drawn=CTFramesetterCreateFrame(fs,vis,path,nil);CTFrameDraw(drawn,ctx)
  let lines=CTFrameGetLines(drawn) as! [CTLine]
  var origins=Array(repeating:CGPoint.zero,count:lines.count);CTFrameGetLineOrigins(drawn,CFRange(location:0,length:0),&origins)
  if let last=origins.last {y=48+last.y-size*0.3-after}
  pos += vis.length
  if pos<a.length {newPage()}
 }
}
func box(_ x:CGFloat,_ top:CGFloat,_ w:CGFloat,_ h:CGFloat,_ title:String,_ detail:String,_ accent:Bool=false) {
 let r=CGRect(x:x,y:top-h,width:w,height:h)
 ctx.setFillColor(NSColor.white.cgColor);ctx.setStrokeColor((accent ? orange : NSColor.lightGray).cgColor);ctx.setLineWidth(accent ? 1.5 : 0.7)
 ctx.addPath(CGPath(roundedRect:r,cornerWidth:10,cornerHeight:10,transform:nil));ctx.drawPath(using:.fillStroke)
 text(title,x+12,top-11,w-24,25,12,.semibold,accent ? orange : ink)
 text(detail,x+12,top-39,w-24,h-44,9,.regular,gray)
}
func line(_ x:CGFloat,_ y1:CGFloat,_ x2:CGFloat,_ y2:CGFloat) {
 ctx.setStrokeColor(gray.cgColor);ctx.setLineWidth(1);ctx.move(to:CGPoint(x:x,y:y1));ctx.addLine(to:CGPoint(x:x2,y:y2));ctx.strokePath()
 ctx.setFillColor(gray.cgColor);ctx.fillEllipse(in:CGRect(x:x2-2,y:y2-2,width:4,height:4))
}
func architecture() {
 newPage();para("目标技术架构",22,.semibold,ink,10);para("沿用原生宿主、现有 Supabase 与同一 Postgres；Worker 是后台执行角色。",11,.regular,gray,15)
 box(M,700,511,92,"cat iOS：今天 / 聊聊 / 我们家","现有设计系统与输入器 · 应用服务 · 账号/家庭 epoch\n加密投影缓存与草稿 · 听写 / 图片 / EventKit / 通知",true)
 line(297,608,297,580)
 box(M,580,511,77,"catpaw-api","鉴权 / membership · 版本化查询 · 幂等命令 / 回执\n既有 Chat runtime / SSE · compiled cards / tools",true)
 line(170,503,170,475);line(425,503,425,475)
 box(M,475,245,86,"共享领域模块","family / memory / schedule\n事实版本 · 来源 · 授权 · CAS")
 box(308,475,245,86,"后台执行角色","现有调度入口收敛维护源后接入\nclaim / lease / generation / reconcile")
 line(165,389,165,352);line(430,389,430,352)
 box(M,352,511,88,"同一 Postgres：事实与恢复权威","家庭 / 成员 / 目标 / 计划 / 事项 / 观察 / 记忆\n命令 receipt · transactional outbox · jobs · tombstone",true)
 box(M,233,155,83,"既有模型路由","共享预算与超时\n无新增付费后备")
 box(220,233,155,83,"受限媒体存储","本次处理 / 明确保留\n到期清扫与来源")
 box(398,233,155,83,"Inbox / APNs","静默、频控与 why-now\n接受 ≠ 用户已看见")
 line(120,264,120,233);line(297,264,297,233);line(475,264,475,233)
 text("权威边界：UI / 模型提出建议，服务端受理命令；外部完成以真实回执为准。\n可靠性：至少一次处理 + 幂等提交 + 未知结果核对，不承诺跨网络 exactly-once。",M,117,W-2*M,52,10,.medium,gray)
}
newPage()
para("cat",42,.bold,orange,24)
para("家庭陪伴场景\n改造技术方案",29,.semibold,ink,24)
para("今天 / 聊聊 / 我们家",18,.medium,ink,16)
para("复用现有视觉与工程底座，把点滴输入变为可确认、可纠正、可持续跟进的家庭记录。",13,.regular,gray,30)
para("v1.0  ·  2026-10-22\n目标基线：main 789ad4fe / 品牌 PR #112\n审计证据：423d25b1 原生与后端源，核心源码无新增差异",11,.regular,gray,20)
para("范围：方案与文档资产。未实施应用代码、生产部署或真实模型调用。\n全部家庭示例虚构；性能与工期数字为提议。",11,.regular,gray,20)
architecture();newPage()
var inCode=false, codeKind="", skippedMermaid=false, tableHeader:[String]=[]
for rawLine in raw.components(separatedBy:"\n") {
 let s=rawLine.trimmingCharacters(in:.whitespaces)
 if s.hasPrefix("```") {inCode = !inCode;if inCode {codeKind=String(s.dropFirst(3));skippedMermaid=codeKind=="mermaid";if skippedMermaid {para("技术架构图见第 2 页；Markdown 附可编辑 Mermaid 源。",10,.regular,gray)}};continue}
 if inCode {if !skippedMermaid {para(s,9,.regular,gray,2)};continue}
 if s.isEmpty {continue}
 if s.hasPrefix("# ") {continue}
 if s.hasPrefix("## ") {if y<190 {newPage()};y-=12;para(String(s.dropFirst(3)),17,.semibold,orange,12);tableHeader=[];continue}
 if s.hasPrefix("### ") {if y<120 {newPage()};para(String(s.dropFirst(4)),13,.semibold,ink,10);tableHeader=[];continue}
 if s.hasPrefix("|") {
  let cells=s.split(separator:"|",omittingEmptySubsequences:false).dropFirst().dropLast().map{String($0).trimmingCharacters(in:.whitespaces)}
  if cells.allSatisfy({$0.allSatisfy({$0=="-" || $0==":" || $0==" "})}) {continue}
  if tableHeader.isEmpty {tableHeader=cells;continue}
  let labels=cells.enumerated().map{i,v in i==0 ? v : "\(i<tableHeader.count ? tableHeader[i]:"")：\(v)"}
  para(labels.joined(separator:"\n"),10,.regular,ink,11);continue
 }
 tableHeader=[]
 para(s)
}
ctx.endPDFPage();ctx.closePDF()
let pdf=PDFDocument(url:URL(fileURLWithPath:output))!
let preview=URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("preview")
try FileManager.default.createDirectory(at:preview,withIntermediateDirectories:true)
var textCount=0
for i in 0..<pdf.pageCount {
 let p=pdf.page(at:i)!;textCount += (p.string ?? "").count
 let image=p.thumbnail(of:NSSize(width:595,height:842),for:.mediaBox)
 let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
 try rep.representation(using:.png,properties:[:])!.write(to:preview.appendingPathComponent(String(format:"page-%02d.png",i+1)))
}
print("pages=\(pdf.pageCount) extracted_characters=\(textCount) output=\(output)")
