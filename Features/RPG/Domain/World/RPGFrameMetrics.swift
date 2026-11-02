import Foundation

struct RPGFrameMetrics:Sendable {
    private var intervals:[Double]=[]
    private var cursor=0
    private var previous:Double?
    private(set) var hitches=0
    private(set) var totalFrames=0
    mutating func pause(){previous=nil}
    mutating func sample(_ time:Double){
        guard time.isFinite else{return}
        defer{previous=time}
        guard let previous,time>previous else{return}
        let delta=time-previous
        guard delta.isFinite else{return}
        if intervals.count<600{intervals.append(delta)}else{intervals[cursor]=delta;cursor=(cursor+1)%600}
        totalFrames+=1;if delta>0.05{hitches+=1}
    }
    var count:Int{intervals.count}
    var framesPerSecond:Double{intervals.isEmpty ? 0:Double(intervals.count)/intervals.reduce(0,+)}
    var p95Milliseconds:Double{let sorted=intervals.sorted();return sorted.isEmpty ? 0:sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]*1000}
}
