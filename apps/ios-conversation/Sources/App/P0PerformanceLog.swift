#if DEBUG
import Foundation

/// Opt-in, bounded offline diagnostics. No body/token data and no UI publication.
final class P0PerformanceLog:@unchecked Sendable {
    static let shared=P0PerformanceLog()
    private let lock=NSLock()
    private var events:[[String:Any]]=[]
    private var timer:DispatchSourceTimer?
    private var active=true,pendingHeartbeat=false
    private var frozen=false
    let enabled:Bool
    private init(){let e=ProcessInfo.processInfo.environment;enabled=e["P0_PERF_RECORDING"] == "1" && UUID(uuidString:e["CF_UI_TEST_STORE"] ?? "") != nil}
    func measure<T>(_ name:String,_ body:() throws -> T) rethrows -> T {
        guard enabled else { return try body() };let start=ProcessInfo.processInfo.systemUptime
        defer { record(name,start:start,end:ProcessInfo.processInfo.systemUptime,main:Thread.isMainThread) }
        return try body()
    }
    func record(_ name:String,start:Double,end:Double,main:Bool,count:Int?=nil) {
        guard enabled else { return };lock.lock();defer{lock.unlock()}
        guard !frozen,events.count<20000 else { return }
        var e:[String:Any]=["phase":name,"start_ns":Int64(start*1e9),"end_ns":Int64(end*1e9),"duration_ms":(end-start)*1000,"main_thread":main]
        if let count {e["count"]=count};events.append(e)
    }
    func mark(_ name:String,count:Int?=nil){let now=ProcessInfo.processInfo.systemUptime;record(name,start:now,end:now,main:Thread.isMainThread,count:count)}
    func setActive(_ value:Bool){lock.lock();active=value;lock.unlock()}
    func startHeartbeat(){
        guard enabled,timer == nil else { return }
        let timer=DispatchSource.makeTimerSource(queue:.global(qos:.userInitiated));timer.schedule(deadline:.now(),repeating:.milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return };self.lock.lock()
            guard self.active,!self.pendingHeartbeat,!self.frozen else { self.lock.unlock();return }
            self.pendingHeartbeat=true;self.lock.unlock();let queued=ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.record("main_dispatch_latency",start:queued,end:ProcessInfo.processInfo.systemUptime,main:true)
                self.lock.lock();self.pendingHeartbeat=false;self.lock.unlock()
            }
        };self.timer=timer;timer.resume()
    }
    func freeze(){lock.lock();frozen=true;lock.unlock();timer?.cancel();timer=nil}
    func snapshot()->[[String:Any]]{lock.lock();defer{lock.unlock()};return events}
}
#endif
