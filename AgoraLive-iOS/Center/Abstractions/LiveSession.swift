//
//  LiveSession.swift
//  AgoraLive
//
//  Created by CavanSu on 2020/3/19.
//  Copyright © 2020 Agora. All rights reserved.
//

import UIKit
import RxSwift
import RxRelay
import AlamoClient

enum LiveType: Int {
    case singleBroadcaster = 1, multiBroadcasters, pkBroadcasters, virtualBroadcasters
    
    var description: String {
        switch self {
        case .multiBroadcasters:
            return NSLocalizedString("Multi_Broadcasters")
        case .singleBroadcaster:
            return NSLocalizedString("Single_Broadcaster")
        case .pkBroadcasters:
            return NSLocalizedString("PK_Live")
        case .virtualBroadcasters:
            return NSLocalizedString("Virtual_Live")
        }
    }
    
    static let list: [LiveType] = [.multiBroadcasters,
                                   .singleBroadcaster,
                                   .pkBroadcasters,
                                   .virtualBroadcasters]
}

class LiveSession: NSObject {
    enum Owner {
        case localUser(LiveRole), otherUser(LiveRole)
        
        var isLocal: Bool {
            switch self {
            case .localUser: return true
            case .otherUser: return false
            }
        }
        
        var user: LiveRole {
            switch self {
            case .otherUser(let user): return user
            case .localUser(let user): return user
            }
        }
    }
    
    var roomId: String
    
    var settings: LocalLiveSettings
    var type: LiveType
    var role: LiveRole?
    var owner: Owner!
    
    private let bag = DisposeBag()
    
    var rtcChannelReport: BehaviorRelay<ChannelReport>?
    var end = PublishRelay<()>()
    var ownerInfoUpdate = PublishRelay<RemoteOwner>()
    
    init(roomId: String, settings: LocalLiveSettings, type: LiveType) {
        self.roomId = roomId
        self.settings = settings
        self.type = type
        super.init()
        self.observe()
    }
    
    typealias JoinedInfo = (seatInfo: [StringAnyDic]?, giftAudience: [StringAnyDic]?, pkInfo: StringAnyDic?, virtualAppearance: String?)
    
    static func create(roomSettings: LocalLiveSettings, type: LiveType, extra: [String: Any]? = nil, success: ((LiveSession) -> Void)? = nil, fail: Completion = nil) {
        let url = URLGroup.liveCreate
        let event = RequestEvent(name: "live-session-create")
        var parameter: StringAnyDic = ["roomName": roomSettings.title, "type": type.rawValue]
        
        if let extra = extra {
            for (key, value) in extra {
                parameter[key] = value
            }
        }
        
        let task = RequestTask(event: event,
                               type: .http(.post, url: url),
                               timeout: .medium,
                               header: ["token": ALKeys.ALUserToken],
                               parameters: parameter)
        
        let successCallback: DicEXCompletion = { (json: ([String: Any])) throws in
            let roomId = try json.getStringValue(of: "data")
            
            let session = LiveSession(roomId: roomId, settings: roomSettings, type: type)
            
            if let success = success {
                success(session)
            }
        }
        let response = ACResponse.json(successCallback)
        
        let retry: ACErrorRetryCompletion = { (error: Error) -> RetryOptions in
            if let fail = fail {
                fail()
            }
            return .resign
        }
        
        let alamo = ALCenter.shared().centerProvideRequestHelper()
        alamo.request(task: task, success: response, failRetry: retry)
    }
    
    func join(success: ((JoinedInfo) throws -> Void)? = nil, fail: Completion = nil ) {
        let client = ALCenter.shared().centerProvideRequestHelper()
        let url = URLGroup.joinLive(roomId: self.roomId)
        let event = RequestEvent(name: "live-session-join")
        let task = RequestTask(event: event,
                               type: .http(.post, url: url),
                               timeout: .low,
                               header: ["token": ALKeys.ALUserToken])
        
        let response = ACResponse.json { [unowned self] (json) in
            let data = try json.getDataObject()
            
            // Local User
            let localUserJson = try data.getDictionaryValue(of: "user")
            try self.initRoleiWhenJoiningWith(info: localUserJson)
            
            // Live Room
            let liveRoom = try data.getDictionaryValue(of: "room")
            try self.updateLiveRoomInfoWhenJoingWith(info: liveRoom)
            
            // join rtc, rtm channel
            ALKeys.AgoraRtcToken = try localUserJson.getStringValue(of: "rtcToken")
            
            let channel = try liveRoom.getStringValue(of: "channelName")
            let agUId = try localUserJson.getIntValue(of: "uid")
            let mediaKit = ALCenter.shared().centerProvideMediaHelper()
            self.setupPublishedVideoStream(self.settings.media)
            
            mediaKit.join(channel: channel, token: ALKeys.AgoraRtcToken, streamId: agUId) { [unowned self] in
                mediaKit.channelReport.subscribe(onNext: { [weak self] (statistic) in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.rtcChannelReport = BehaviorRelay(value: statistic)
                }).disposed(by: self.bag)
            }
            
            let rtm = ALCenter.shared().centerProvideRTMHelper()
            
            // multiBroadcasters, virtualBroadcasters have seatInfo
            var seatInfo: [StringAnyDic]?
            if self.type == .multiBroadcasters || self.type == .virtualBroadcasters {
                seatInfo = try liveRoom.getListValue(of: "coVideoSeats")
            }
            
            // only pkBroadcaster has pkInfo
            var pkInfo: StringAnyDic?
            if self.type == .pkBroadcasters {
                pkInfo = try liveRoom.getDictionaryValue(of: "pk")
            }
            
            var virtualAppearance: String?
            
            if self.type == .virtualBroadcasters, self.role!.type != .audience {
                virtualAppearance = try localUserJson.getStringValue(of: "virtualAvatar")
            }
            
            let giftAudience = try? liveRoom.getListValue(of: "rankUsers")
            
            rtm.joinChannel(channel, success: {
                guard let success = success else {
                    return
                }
                do {
                    try success((seatInfo, giftAudience, pkInfo, virtualAppearance))
                } catch {
                    if let fail = fail {
                        fail()
                    }
                }
            }) { [unowned mediaKit] (error) -> RetryOptions in
                mediaKit.leaveChannel()
                return .resign
            }
        }
        
        let retry: ACErrorRetryCompletion = { (error: Error) -> RetryOptions in
            if let fail = fail {
                fail()
            }
            return .resign
        }
        
        client.request(task: task, success: response, failRetry: retry)
    }
    
    @discardableResult func audienceToBroadcaster() -> LiveRole {
        guard let audience = self.role as? LiveAudience else {
            fatalError()
        }
        
        let media = ALCenter.shared().centerProvideMediaHelper()
        media.capture.audio = .on
        try! media.capture.video(.on)
        var permission = audience.permission
        permission.insert(.camera)
        permission.insert(.mic)
        let role = LiveBroadcaster(info: audience.info,
                                         permission: permission,
                                         agUId: audience.agUId,
                                         giftRank: audience.giftRank)
        self.role = role
        self.setupPublishedVideoStream(settings.media)
        return role
    }
    
    @discardableResult func broadcasterToAudience() -> LiveRole {
        guard let broadcaster = self.role as? LiveBroadcaster else {
            fatalError()
        }
        
        let media = ALCenter.shared().centerProvideMediaHelper()
        media.capture.audio = .off
        try! media.capture.video(.off)
        let role = LiveAudience(info: broadcaster.info,
                                agUId: broadcaster.agUId,
                                giftRank: broadcaster.giftRank)
        
        self.role = role
        return role
    }
    
    func setupPublishedVideoStream(_ settings: LocalLiveSettings.VideoConfiguration) {
        let mediaKit = ALCenter.shared().centerProvideMediaHelper()
        
        mediaKit.setupPublishedVideoStream(resolution: settings.resolution,
                                           frameRate: settings.frameRate,
                                           bitRate: settings.bitRate)
    }
    
    func leave() {
        let mediaKit = ALCenter.shared().centerProvideMediaHelper()
        let rtm = ALCenter.shared().centerProvideRTMHelper()
        let client = ALCenter.shared().centerProvideRequestHelper()
        role = nil
        mediaKit.leaveChannel()
        try? mediaKit.capture.video(.off)
        mediaKit.capture.audio = .off
        
        rtm.leaveChannel()
        
        let event = RequestEvent(name: "live-session-leave")
        let url = URLGroup.leaveLive(roomId: self.roomId)
        let task = RequestTask(event: event, type: .http(.post, url: url))
        client.request(task: task)
    }
    
    deinit {
        let rtm = ALCenter.shared().centerProvideRTMHelper()
        rtm.removeReceivedChannelMessage(observer: self)
    }
}

private extension LiveSession {
    func initRoleiWhenJoiningWith(info: StringAnyDic) throws {
        // Local User
        let userInfo = try BasicUserInfo(dic: info)
        let permission = try LivePermission.permission(dic: info)
        let roleType = try info.getEnum(of: "role", type: LiveRoleType.self)
        
        let giftRank = try info.getIntValue(of: "rank")
        let agUId = try info.getIntValue(of: "uid")
        
        // Create Live role
        switch roleType {
        case .owner:
            self.role = LiveOwner(info: userInfo, permission: permission, agUId: agUId)
        case .broadcaster:
            self.role = LiveBroadcaster(info: userInfo, permission: permission, agUId: agUId, giftRank: giftRank)
        case .audience:
            self.role = LiveAudience(info: userInfo, agUId: agUId, giftRank: giftRank)
        }
    }
    
    func updateLiveRoomInfoWhenJoingWith(info: StringAnyDic) throws {
        // Live room owner
        var ownerJson = try info.getDictionaryValue(of: "owner")
        ownerJson["avatar"] = "Fake"
        let ownerObj = try RemoteOwner(dic: ownerJson)
        
        guard let current = ALCenter.shared().current else {
            fatalError()
        }
        
        if ownerObj.info.userId == current.info.value.userId {
            self.owner = .localUser(ownerObj)
        } else {
            self.owner = .otherUser(ownerObj)
        }
        
        // Live type check
        let liveType = try info.getEnum(of: "type", type: LiveType.self)
        
        guard self.type == liveType else {
            throw AGEError.fail("local live type is not equal to server live type")
        }
    }
}

private extension LiveSession {
    func observe() {
        let rtm = ALCenter.shared().centerProvideRTMHelper()
        rtm.addReceivedChannelMessage(observer: self) { [weak self] (json) in
            guard let cmd = try? json.getEnum(of: "cmd", type: ALChannelMessage.AType.self) else {
                return
            }
            
            guard let strongSelf = self else {
                return
            }
            
            switch cmd {
            case .liveEnd:
                strongSelf.end.accept(())
            case .owner:
                let data = try json.getDataObject()
                let owner = try RemoteOwner(dic: data)
                
                guard let tOwner = strongSelf.owner else {
                    return
                }
                
                if !tOwner.isLocal {
                    strongSelf.owner = .otherUser(owner)
                }
                
                strongSelf.ownerInfoUpdate.accept(owner)
            default:
                break
            }
        }
    }
}
