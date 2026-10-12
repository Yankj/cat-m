import Foundation
@main struct DeviceTrialEndpointRunner {
 static func main() throws {
  let project = URL(string:"https://dbyklgxdvjbutxzsjeth.supabase.co")!,key = "sb_publishable_public_fixture_0123456789",scope = UUID(),base = URL(string:"https://dbyklgxdvjbutxzsjeth.supabase.co/functions/v1/catpaw-agent")!
  let auth = try NativeAuthConfiguration(projectURL:project,publishableKey:key,backendOrigin:base,serverScopeID:scope)
  let chat = try NativeChatConfiguration(origin:auth.backendOrigin,localScope:Profiles.user,serverScopeID:scope,publishableKey:key)
  let r = try chat.makeRequest(route:"/catpaw/v1/scopes/"+scope.uuidString+"/runs/original?after_sequence=7",authorization:"Bearer test-user-token")
  precondition(r.url!.path.hasPrefix("/functions/v1/catpaw-agent/catpaw/v1/scopes/"));precondition(r.url!.query == "after_sequence=7");precondition(r.value(forHTTPHeaderField:"apikey") == key);precondition(r.value(forHTTPHeaderField:"Authorization") == "Bearer test-user-token")
  let root = try NativeChatConfiguration(origin:URL(string:"https://api.example.invalid")!,localScope:Profiles.user,serverScopeID:scope)
  let rootRequest = try root.makeRequest(route:"/readyz",authorization:"Bearer token");precondition(rootRequest.url!.absoluteString == "https://api.example.invalid/readyz")
  var rejected = 0
  for text in ["https://user:pass@api.example.invalid", "https://api.example.invalid?token=x", "https://api.example.invalid/#fragment", "https://api.example.invalid/functions/v1/../escape", "https://api.example.invalid/functions/v1/%2e%2e", "http://api.example.invalid", "https://api.example.invalid/unapproved-prefix"] {
   do { _ = try NativeAuthConfiguration(projectURL:project,publishableKey:key,backendOrigin:URL(string:text)!,serverScopeID:scope);preconditionFailure("unsafe base accepted") } catch { rejected += 1 }
  }
  for key in ["sb_secret_do_not_ship", "eyJlegacyJwt", "sk-model-secret"] { do { _ = try NativeChatConfiguration(origin:base,localScope:Profiles.user,serverScopeID:scope,publishableKey:key);preconditionFailure("secret accepted") } catch { rejected += 1 } }
  do { _ = try chat.makeRequest(route:"//other.example.invalid/leak",authorization:"Bearer token");preconditionFailure("cross-host accepted") } catch { rejected += 1 }
  print("PASS: Edge prefix/query/header/root compatibility + 11 unsafe URL/key cases rejected; 0 HTTP")
 }
}
