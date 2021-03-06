import Flutter
import UIKit
import AVFoundation
import PushKit
import TwilioVoice
import CallKit

public class SwiftFlutterTwilioVoicePlugin: NSObject, FlutterPlugin,  FlutterStreamHandler, PKPushRegistryDelegate, TVONotificationDelegate, TVOCallDelegate, AVAudioPlayerDelegate, CXProviderDelegate {

    var _result: FlutterResult?
    private var eventSink: FlutterEventSink?

    //var baseURLString = ""
    // If your token server is written in PHP, accessTokenEndpoint needs .php extension at the end. For example : /accessToken.php
    //var accessTokenEndpoint = "/accessToken"
    var accessToken:String?
    var identity = "alice"
    var callTo: String = "error"
    var deviceTokenString: String?
    var callArgs: Dictionary<String, AnyObject> = [String: AnyObject]()

    var voipRegistry: PKPushRegistry
    var incomingPushCompletionCallback: (()->Swift.Void?)? = nil

   var callInvite:TVOCallInvite?
   var call:TVOCall?
   var callKitCompletionCallback: ((Bool)->Swift.Void?)? = nil
   var audioDevice: TVODefaultAudioDevice = TVODefaultAudioDevice()

   var callKitProvider: CXProvider
   var callKitCallController: CXCallController
   var userInitiatedDisconnect: Bool = false
   var callOutgoing: Bool = false

    static var appName: String {
        get {
            return (Bundle.main.infoDictionary!["CFBundleDisplayName"] as? String) ?? "Define CFBundleDisplayName"
        }
    }

    public override init() {

        //isSpinning = false
        voipRegistry = PKPushRegistry.init(queue: DispatchQueue.main)
        let configuration = CXProviderConfiguration(localizedName: SwiftFlutterTwilioVoicePlugin.appName)
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        if let callKitIcon = UIImage(named: "AppIcon") {
            configuration.iconTemplateImageData = callKitIcon.pngData()
        }

        callKitProvider = CXProvider(configuration: configuration)
        callKitCallController = CXCallController()

        //super.init(coder: aDecoder)
        super.init()

        callKitProvider.setDelegate(self, queue: nil)

        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = Set([PKPushType.voIP])


         let appDelegate = UIApplication.shared.delegate
         guard let controller = appDelegate?.window??.rootViewController as? FlutterViewController else {
         fatalError("rootViewController is not type FlutterViewController")
         }
         let registrar = controller.registrar(forPlugin: "flutter_twilio_voice")
         let eventChannel = FlutterEventChannel(name: "flutter_twilio_voice/events", binaryMessenger: registrar.messenger())

         eventChannel.setStreamHandler(self)

    }


      deinit {
          // CallKit has an odd API contract where the developer must call invalidate or the CXProvider is leaked.
          callKitProvider.invalidate()
      }


  public static func register(with registrar: FlutterPluginRegistrar) {

    let instance = SwiftFlutterTwilioVoicePlugin()
    let methodChannel = FlutterMethodChannel(name: "flutter_twilio_voice/messages", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(name: "flutter_twilio_voice/events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

  }

  public func handle(_ flutterCall: FlutterMethodCall, result: @escaping FlutterResult) {
    _result = result

    let arguments:Dictionary<String, AnyObject> = flutterCall.arguments as! Dictionary<String, AnyObject>;

    if flutterCall.method == "tokens" {
        guard let token = arguments["accessToken"] as? String else {return}
        self.accessToken = token
        if let deviceToken = deviceTokenString, let token = accessToken {
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
            TwilioVoice.register(withAccessToken: token, deviceToken: deviceToken) { (error) in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                }
                else {
                    self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                }
            }
        } else if let deviceToken = arguments["deviceToken"] as? String, let token = accessToken {
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
            TwilioVoice.register(withAccessToken: token, deviceToken: deviceToken) { (error) in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                }
                else {
                    self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                }
            }
        }
    } else if flutterCall.method == "makeCall" {
        guard let callTo = arguments["to"] as? String else {return}
        guard let callFrom = arguments["from"] as? String else {return}
        let callToDisplayName:String = arguments["toDisplayName"] as? String ?? callTo
        self.callArgs = arguments
        self.callOutgoing = true
        //guard let accessTokenUrl = arguments["accessTokenUrl"] as? String else {return}
        //self.accessTokenEndpoint = accessTokenUrl
        self.callTo = callTo
        self.identity = callFrom
        makeCall(to: callTo, displayName: callToDisplayName)
    }
    else if flutterCall.method == "muteCall"
    {
        if (self.call != nil) {
           let muted = self.call!.isMuted
           self.call!.isMuted = !muted
           guard let eventSink = eventSink else {
               return
           }
           eventSink(!muted ? "Mute" : "Unmute")
        } else {
            let ferror: FlutterError = FlutterError(code: "MUTE_ERROR", message: "No call to be muted", details: nil)
            _result!(ferror)
        }
    }
    else if flutterCall.method == "toggleSpeaker"
    {
        guard let speakerIsOn = arguments["speakerIsOn"] as? Bool else {return}
        toggleAudioRoute(toSpeaker: speakerIsOn)
        guard let eventSink = eventSink else {
            return
        }
        eventSink(speakerIsOn ? "Speaker On" : "Speaker Off")
    }
    else if flutterCall.method == "isOnCall"
        {
            result(self.call != nil);
            return;
        }
    else if flutterCall.method == "sendDigits"
    {
        guard let digits = arguments["digits"] as? String else {return}
        if (self.call != nil) {
            self.call!.sendDigits(digits);
        }
    }
    /* else if flutterCall.method == "receiveCalls"
    {
        guard let clientIdentity = arguments["clientIdentifier"] as? String else {return}
        self.identity = clientIdentity;
    } */
    else if flutterCall.method == "holdCall" {
        if (self.call != nil) {

            let hold = self.call!.isOnHold
            self.call!.isOnHold = !hold
            guard let eventSink = eventSink else {
                return
            }
            eventSink(!hold ? "Hold" : "Unhold")
        }
    }
    else if flutterCall.method == "answer" {
        // nuthin
    }
    else if flutterCall.method == "unregister" {
        guard let token = arguments["accessToken"] as? String else {return}
        guard let deviceToken = deviceTokenString else {
          return
        }
        self.unregisterTokens(token: token, deviceToken: deviceToken)
    }
    else if flutterCall.method == "hangUp"
    {
        if (self.call != nil && self.call?.state == .connected) {
            self.sendPhoneCallEvents(description: "LOG|hangUp method invoked", isError: false)
            self.userInitiatedDisconnect = true
            performEndCallAction(uuid: self.call!.uuid)
            //self.toggleUIState(isEnabled: false, showCallControl: false)
        }
    }
    result(true)
  }

  func makeCall(to: String, displayName: String)
  {
        if (self.call != nil && self.call?.state == .connected) {
            self.userInitiatedDisconnect = true
            performEndCallAction(uuid: self.call!.uuid)
            //self.toggleUIState(isEnabled: false, showCallControl: false)
        } else {
            let uuid = UUID()
            let handle = displayName

            self.checkRecordPermission { (permissionGranted) in
                if (!permissionGranted) {
                    let alertController: UIAlertController = UIAlertController(title: SwiftFlutterTwilioVoicePlugin.appName + " Permission",
                                                                               message: "Microphone permission not granted",
                                                                               preferredStyle: .alert)

                    let continueWithMic: UIAlertAction = UIAlertAction(title: "Continue without microphone",
                                                                       style: .default,
                                                                       handler: { (action) in
                        self.performStartCallAction(uuid: uuid, handle: handle)
                    })
                    alertController.addAction(continueWithMic)

                    let goToSettings: UIAlertAction = UIAlertAction(title: "Settings",
                                                                    style: .default,
                                                                    handler: { (action) in
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                  options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: false],
                                                  completionHandler: nil)
                    })
                    alertController.addAction(goToSettings)

                    let cancel: UIAlertAction = UIAlertAction(title: "Cancel",
                                                              style: .cancel,
                                                              handler: { (action) in
                        //self.toggleUIState(isEnabled: true, showCallControl: false)
                        //self.stopSpin()
                    })
                    alertController.addAction(cancel)
                    guard let currentViewController = UIApplication.shared.keyWindow?.topMostViewController() else {
                        return
                    }
                    currentViewController.present(alertController, animated: true, completion: nil)

                } else {
                    self.performStartCallAction(uuid: uuid, handle: handle)
                }
            }
        }
    }

    func checkRecordPermission(completion: @escaping (_ permissionGranted: Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case AVAudioSessionRecordPermission.granted:
            // Record permission already granted.
            completion(true)
            break
        case AVAudioSessionRecordPermission.denied:
            // Record permission denied.
            completion(false)
            break
        case AVAudioSessionRecordPermission.undetermined:
            // Requesting record permission.
            // Optional: pop up app dialog to let the users know if they want to request.
            AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
                completion(granted)
            })
            break
        default:
            completion(false)
            break
        }
    }


  // MARK: PKPushRegistryDelegate
      public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
          self.sendPhoneCallEvents(description: "LOG|pushRegistry:didUpdatePushCredentials:forType:", isError: false)

          if (type != .voIP) {
              return
          }

          //guard let accessToken = fetchAccessToken() else {
          //    return
          //}

          let deviceToken = credentials.token.map { String(format: "%02x", $0) }.joined()

          self.sendPhoneCallEvents(description: "LOG|pushRegistry:attempting to register with twilio", isError: false)
          if let token = accessToken {
              TwilioVoice.register(withAccessToken: token, deviceToken: deviceToken) { (error) in
                  if let error = error {
                      self.sendPhoneCallEvents(description: "LOG|An error occurred while registering: \(error.localizedDescription)", isError: false)
                  }
                  else {
                      self.sendPhoneCallEvents(description: "LOG|Successfully registered for VoIP push notifications.", isError: false)
                  }
              }
          }

          self.deviceTokenString = deviceToken
          self.sendPhoneCallEvents(description: "DEVICETOKEN|\(deviceToken)", isError: false)
      }

      public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
          self.sendPhoneCallEvents(description: "LOG|pushRegistry:didInvalidatePushTokenForType:", isError: false)

          if (type != .voIP) {
              return
          }

          self.unregister()
      }

      func unregister() {

          guard let deviceToken = deviceTokenString, let token = accessToken else {
              return
          }

          self.unregisterTokens(token: token, deviceToken: deviceToken)
      }

      func unregisterTokens(token: String, deviceToken: String) {
          TwilioVoice.unregister(withAccessToken: token, deviceToken: deviceToken) { (error) in
              if let error = error {
                  self.sendPhoneCallEvents(description: "LOG|An error occurred while unregistering: \(error.localizedDescription)", isError: false)
              } else {
                  self.sendPhoneCallEvents(description: "LOG|Successfully unregistered from VoIP push notifications.", isError: false)
              }
          }
      }

    /**
         * Try using the `pushRegistry:didReceiveIncomingPushWithPayload:forType:withCompletionHandler:` method if
         * your application is targeting iOS 11. According to the docs, this delegate method is deprecated by Apple.
         */
        public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:", isError: false)

            if (type == PKPushType.voIP) {
                TwilioVoice.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
            }
        }

        /**
         * This delegate method is available on iOS 11 and above. Call the completion handler once the
         * notification payload is passed to the `TwilioVoice.handleNotification()` method.
         */
        public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
            self.sendPhoneCallEvents(description: "LOG|pushRegistry:didReceiveIncomingPushWithPayload:forType:completion:", isError: false)
            // Save for later when the notification is properly handled.
            self.incomingPushCompletionCallback = completion

            if (type == PKPushType.voIP) {
                TwilioVoice.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
            }

            if let version = Float(UIDevice.current.systemVersion), version < 13.0 {
                // Save for later when the notification is properly handled.
                self.incomingPushCompletionCallback = completion
            } else {
                /**
                * The Voice SDK processes the call notification and returns the call invite synchronously. Report the incoming call to
                * CallKit and fulfill the completion before exiting this callback method.
                */
                completion()
            }
        }

        func incomingPushHandled() {
            if let completion = self.incomingPushCompletionCallback {
                completion()
                self.incomingPushCompletionCallback = nil
            }
        }

        // MARK: TVONotificaitonDelegate
    public func callInviteReceived(_ ci: TVOCallInvite) {
            self.sendPhoneCallEvents(description: "LOG|callInviteReceived:", isError: false)

            var from:String = ci.from ?? "Voice Bot"
            from = from.replacingOccurrences(of: "client:", with: "")

            reportIncomingCall(from: from, uuid: ci.uuid)
            self.callInvite = ci
        }

    public func cancelledCallInviteReceived(_ cancelledCallInvite: TVOCancelledCallInvite, error: Error) {
            self.sendPhoneCallEvents(description: "LOG|cancelledCallInviteCanceled:", isError: false)

            if (self.callInvite == nil) {
                self.sendPhoneCallEvents(description: "LOG|No pending call invite", isError: false)
                return
            }

            if let ci = self.callInvite {
                performEndCallAction(uuid: ci.uuid)
            }
        }

        // MARK: TVOCallDelegate
    public func callDidStartRinging(_ call: TVOCall) {
        let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
        let from = (call.from ?? self.identity)
        let to = (call.to ?? self.callTo)
        self.sendPhoneCallEvents(description: "Ringing|\(from)|\(to)|\(direction)", isError: false)

            //self.placeCallButton.setTitle("Ringing", for: .normal)
        }

    public func callDidConnect(_ call: TVOCall) {
            let direction = (self.callOutgoing ? "Outgoing" : "Incoming")
            let from = (call.from ?? self.identity)
            let to = (call.to ?? self.callTo)
            self.sendPhoneCallEvents(description: "Connected|\(from)|\(to)|\(direction)", isError: false)

            self.callKitCompletionCallback!(true)

            //self.placeCallButton.setTitle("Hang Up", for: .normal)

            //toggleUIState(isEnabled: true, showCallControl: true)
            //stopSpin()
            toggleAudioRoute(toSpeaker: false)
        }

        public func call(_ call: TVOCall, isReconnectingWithError error: Error) {
            self.sendPhoneCallEvents(description: "LOG|call:isReconnectingWithError:", isError: false)

            //self.placeCallButton.setTitle("Reconnecting", for: .normal)

            //toggleUIState(isEnabled: false, showCallControl: false)
        }

        public func callDidReconnect(_ call: TVOCall) {
            self.sendPhoneCallEvents(description: "LOG|callDidReconnect:", isError: false)

            //self.placeCallButton.setTitle("Hang Up", for: .normal)

            //toggleUIState(isEnabled: true, showCallControl: true)
        }

        public func call(_ call: TVOCall, didFailToConnectWithError error: Error) {
            self.sendPhoneCallEvents(description: "LOG|Call failed to connect: \(error.localizedDescription)", isError: false)

            if let completion = self.callKitCompletionCallback {
                completion(false)
            }

            performEndCallAction(uuid: call.uuid)
            callDisconnected()
        }

    public func call(_ call: TVOCall, didDisconnectWithError error: Error?) {
            self.sendPhoneCallEvents(description: "Call Ended", isError: false)
            if let error = error {
                self.sendPhoneCallEvents(description: "Call Failed: \(error.localizedDescription)", isError: true)
            }

            if !self.userInitiatedDisconnect {
                var reason = CXCallEndedReason.remoteEnded

                if error != nil {
                    reason = .failed
                }

                self.callKitProvider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
            }

            callDisconnected()
        }

        func callDisconnected() {
            if (self.call != nil) {
                self.call = nil
            }
            if (self.callInvite != nil) {
                self.callInvite = nil
            }

            self.callOutgoing = false
            self.userInitiatedDisconnect = false

            //stopSpin()
            //toggleUIState(isEnabled: true, showCallControl: false)
            //self.placeCallButton.setTitle("Call", for: .normal)
        }


        // MARK: AVAudioSession
        func toggleAudioRoute(toSpeaker: Bool) {
            // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver. Use port override to switch the route.
            audioDevice.block = {
                kTVODefaultAVAudioSessionConfigurationBlock()
                do {
                    if (toSpeaker) {
                        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                    } else {
                        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                    }
                } catch {
                    self.sendPhoneCallEvents(description: "LOG|\(error.localizedDescription)", isError: false)
                }
            }
            audioDevice.block()
        }

    // MARK: CXProviderDelegate
        public func providerDidReset(_ provider: CXProvider) {
            self.sendPhoneCallEvents(description: "LOG|providerDidReset:", isError: false)
            audioDevice.isEnabled = true
        }

        public func providerDidBegin(_ provider: CXProvider) {
            self.sendPhoneCallEvents(description: "LOG|providerDidBegin", isError: false)
        }

        public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
            self.sendPhoneCallEvents(description: "LOG|provider:didActivateAudioSession:", isError: false)
            audioDevice.isEnabled = true
        }

        public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
            self.sendPhoneCallEvents(description: "LOG|provider:didDeactivateAudioSession:", isError: false)
        }

        public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
            self.sendPhoneCallEvents(description: "LOG|provider:timedOutPerformingAction:", isError: false)
        }

        public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
            self.sendPhoneCallEvents(description: "LOG|provider:performStartCallAction:", isError: false)

            //toggleUIState(isEnabled: false, showCallControl: false)
            //startSpin()

            audioDevice.isEnabled = false
            audioDevice.block()

            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())

            self.performVoiceCall(uuid: action.callUUID, client: "") { (success) in
                if (success) {
                    provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                    action.fulfill()
                } else {
                    action.fail()
                }
            }
        }

        public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
            self.sendPhoneCallEvents(description: "LOG|provider:performAnswerCallAction:", isError: false)

            audioDevice.isEnabled = false
            audioDevice.block()

            self.performAnswerVoiceCall(uuid: action.callUUID) { (success) in
                if (success) {
                    action.fulfill()
                } else {
                    action.fail()
                }
            }

            action.fulfill()
        }

        public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
            self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction:", isError: false)

            audioDevice.isEnabled = true

            if (self.call != nil) {
                self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: disconnecting call", isError: false)
                self.call?.disconnect()
                //self.callInvite = nil
                //self.call = nil
                action.fulfill()
                return
            }

            if (self.callInvite != nil) {
                self.sendPhoneCallEvents(description: "LOG|provider:performEndCallAction: rejecting call", isError: false)
                self.callInvite?.reject()
                //self.callInvite = nil
                //self.call = nil
                action.fulfill()
                return
            }
        }

        public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
            self.sendPhoneCallEvents(description: "LOG|provider:performSetHeldAction:", isError: false)
            if let call = self.call {
                call.isOnHold = action.isOnHold
                action.fulfill()
            } else {
                action.fail()
            }
        }

        public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
            self.sendPhoneCallEvents(description: "LOG|provider:performSetMutedAction:", isError: false)

            if let call = self.call {
                call.isMuted = action.isMuted
                action.fulfill()
            } else {
                action.fail()
            }
        }

        // MARK: Call Kit Actions
        func performStartCallAction(uuid: UUID, handle: String) {
            let callHandle = CXHandle(type: .generic, value: handle)
            let startCallAction = CXStartCallAction(call: uuid, handle: callHandle)
            let transaction = CXTransaction(action: startCallAction)

            callKitCallController.request(transaction)  { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request failed: \(error.localizedDescription)", isError: false)
                    return
                }

                self.sendPhoneCallEvents(description: "LOG|StartCallAction transaction request successful", isError: false)

                let callUpdate = CXCallUpdate()
                callUpdate.remoteHandle = callHandle
                callUpdate.supportsDTMF = true
                callUpdate.supportsHolding = true
                callUpdate.supportsGrouping = false
                callUpdate.supportsUngrouping = false
                callUpdate.hasVideo = false

                self.callKitProvider.reportCall(with: uuid, updated: callUpdate)
            }
        }

        func reportIncomingCall(from: String, uuid: UUID) {
            let callHandle = CXHandle(type: .generic, value: from)

            let callUpdate = CXCallUpdate()
            callUpdate.remoteHandle = callHandle
            callUpdate.supportsDTMF = true
            callUpdate.supportsHolding = true
            callUpdate.supportsGrouping = false
            callUpdate.supportsUngrouping = false
            callUpdate.hasVideo = false

            callKitProvider.reportNewIncomingCall(with: uuid, update: callUpdate) { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "LOG|Failed to report incoming call successfully: \(error.localizedDescription).", isError: false)
                } else {
                    self.sendPhoneCallEvents(description: "LOG|Incoming call successfully reported.", isError: false)
                }
            }
        }

        func performEndCallAction(uuid: UUID) {

            self.sendPhoneCallEvents(description: "LOG|performEndCallAction method invoked", isError: false)

            let endCallAction = CXEndCallAction(call: uuid)
            let transaction = CXTransaction(action: endCallAction)

            callKitCallController.request(transaction) { error in
                if let error = error {
                    self.sendPhoneCallEvents(description: "End Call Failed: \(error.localizedDescription).", isError: true)
                } else {
                    self.sendPhoneCallEvents(description: "Call Ended", isError: false)
                }
            }
        }

        func performVoiceCall(uuid: UUID, client: String?, completionHandler: @escaping (Bool) -> Swift.Void) {
            guard let token = accessToken else {
                completionHandler(false)
                return
            }

            let connectOptions: TVOConnectOptions = TVOConnectOptions(accessToken: token) { (builder) in
                builder.params = ["PhoneNumber": self.callTo, "From": self.identity]
                for (key, value) in self.callArgs {
                    if (key != "to" && key != "toDisplayName" && key != "from") {
                        builder.params[key] = "\(value)"
                    }
                }
                builder.uuid = uuid
            }
            let theCall = TwilioVoice.connect(with: connectOptions, delegate: self)
            self.call = theCall
            self.callKitCompletionCallback = completionHandler
        }

        func performAnswerVoiceCall(uuid: UUID, completionHandler: @escaping (Bool) -> Swift.Void) {
            if let ci = self.callInvite {
                let acceptOptions: TVOAcceptOptions = TVOAcceptOptions(callInvite: ci) { (builder) in
                    builder.uuid = ci.uuid
                }
                self.sendPhoneCallEvents(description: "LOG|performAnswerVoiceCall: answering call", isError: false)
                let theCall = ci.accept(with: acceptOptions, delegate: self)
                self.call = theCall
                self.callKitCompletionCallback = completionHandler

                guard #available(iOS 13, *) else {
                    self.incomingPushHandled()
                    return
                }
            } else {
                self.sendPhoneCallEvents(description: "LOG|No CallInvite matches the UUID", isError: false)
            }
        }

    public func onListen(withArguments arguments: Any?,
                         eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(TVOCallDelegate.call(_:didDisconnectWithError:)),
            name: NSNotification.Name(rawValue: "PhoneCallEvent"),
            object: nil)

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        eventSink = nil
        return nil
    }

    private func sendPhoneCallEvents(description: String, isError: Bool) {
        NSLog(description)
        guard let eventSink = eventSink else {
            return
        }

        if isError
        {
            eventSink(FlutterError(code: "unavailable",
                                   message: description,
                                   details: nil))
        }
        else
        {
            eventSink(description)
        }
    }



}

extension UIWindow {
    func topMostViewController() -> UIViewController? {
        guard let rootViewController = self.rootViewController else {
            return nil
        }
        return topViewController(for: rootViewController)
    }

    func topViewController(for rootViewController: UIViewController?) -> UIViewController? {
        guard let rootViewController = rootViewController else {
            return nil
        }
        guard let presentedViewController = rootViewController.presentedViewController else {
            return rootViewController
        }
        switch presentedViewController {
        case is UINavigationController:
            let navigationController = presentedViewController as! UINavigationController
            return topViewController(for: navigationController.viewControllers.last)
        case is UITabBarController:
            let tabBarController = presentedViewController as! UITabBarController
            return topViewController(for: tabBarController.selectedViewController)
        default:
            return topViewController(for: presentedViewController)
        }
    }


}
