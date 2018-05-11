//
//  SBABridgeConfiguration.swift
//  BridgeApp
//
//  Copyright © 2018 Sage Bionetworks. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// 1.  Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// 2.  Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation and/or
// other materials provided with the distribution.
//
// 3.  Neither the name of the copyright holder(s) nor the names of any contributors
// may be used to endorse or promote products derived from this software without
// specific prior written permission. No license is granted to the trademarks of
// the copyright holders even if such marks are included in this software.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation
import BridgeSDK

/// `SBABridgeConfiguration` is used as a wrapper for combining task group and task info objects that are
/// singletons with the `SBBActivity` objects that contain a subset of the information used to implement
/// the `RSDTaskInfo` protocol.
open class SBABridgeConfiguration {
    
    /// The shared singleton.
    public static var shared = SBABridgeConfiguration()
    
    /// A mapping of the activity groups defined for this application.
    open var activityGroups : [SBAActivityGroup] = []
    
    /// A mapping of the activity infos defined for this application.
    open var activityInfoMap : [String : SBAActivityInfo] = [:]
    
    /// A mapping of schema references.
    open var schemaReferenceMap : [String : SBBSchemaReference] = [:]
    
    /// A mapping of tasks to an identifier.
    open var taskMap : [String : RSDTask] = [:]
    
    /// A mapping of schema identifiers to task identifiers.
    open var schemaIdentifierMap : [String : SBAModuleIdentifier] = [:]
    
    /// The duration of the study. Default = 1 year.
    open var studyDuration : DateComponents = {
        var studyDuration = DateComponents()
        studyDuration.year = 1
        return studyDuration
    }()
    
    /// Set up BridgeSDK including loading any cached configurations.
    open func setupBridge(with factory: RSDFactory) {
        guard !_hasInitialized else { return }
        _hasInitialized = true
        
        // Insert this bundle into the list of localized bundles.
        Localization.insert(bundle: LocalizationBundle(Bundle(for: SBABridgeConfiguration.self)),
                            at: UInt(Localization.allBundles.count))
        
        // Set the factory to this one by default.
        RSDFactory.shared = factory
        
        BridgeSDK.setup()
        
        if let appConfig = BridgeSDK.appConfig() {
            setup(with: appConfig)
        } else {
            // this is the first time this app has been set up for Bridge and the appConfig hasn't
            // had time to load yet, so we'll explicitly request it and defer that part of configuration
            // until its completion handler gets called.
            (SBBComponentManager.component(SBBStudyManager.classForCoder()) as! SBBStudyManagerProtocol).getAppConfig { (response, error) in
                guard error == nil, let appConfig = response as? SBBAppConfig else { return }
                self.setup(with: appConfig)
            }
            return
        }
    }
    private var _hasInitialized = false
    
    /// Decode the `clientData`, schemas, and surveys for this application.
    open func setup(with appConfig: SBBAppConfig) {
        if let schemas = appConfig.schemaReferences as? [SBBSchemaReference] {
            // Map the schemas
            schemas.forEach { self.schemaReferenceMap[$0.identifier] = $0 }
        }
        if let clientData = appConfig.clientData {
            // If there is a clientData object, need to serialize it back into data before decoding it.
            do {
                let decoder = RSDFactory.shared.createJSONDecoder()
                let mappingObject = try decoder.decode(SBAActivityMappingObject.self, from: clientData)
                mappingObject.tasks?.forEach { self.taskMap[$0.identifier] = $0 }
                self.activityGroups = mappingObject.groups ?? []
                mappingObject.activityList?.forEach { self.activityInfoMap[$0.identifier] = $0 }
                if let studyDuration = mappingObject.studyDuration {
                    self.studyDuration = studyDuration
                }
                self.schemaIdentifierMap = mappingObject.schemaIdentifierMap ?? [:]
            } catch let err {
                debugPrint("Failed to decode the clientData object: \(err)")
            }
        }
    }
    
    /// Update the mapping by adding the given activity info.
    public func addMapping(with activityInfo: SBAActivityInfo) {
        self.activityInfoMap[activityInfo.identifier] = activityInfo
    }
    
    /// Update the mapping by adding the given activity group.
    public func addMapping(with activityGroup: SBAActivityGroup) {
        self.activityGroups.append(activityGroup)
    }
    
    /// Update the mapping by adding the given schema reference.
    public func addMapping(with schemaReference: SBBSchemaReference) {
        self.schemaReferenceMap[schemaReference.identifier] = schemaReference
    }
    
    /// Update the mapping by adding the given schema reference.
    public func addMapping(with task: RSDTask) {
        self.taskMap[task.identifier] = task
    }
    
    /// Return the task transformer for the given activity reference.
    open func instantiateTaskTransformer(for activityReference: SBASingleActivityReference) -> RSDTaskTransformer? {
        // Exit early if this is a survey reference or if the activity info uses an embedded resource.
        if let surveyReference = activityReference as? SBBSurveyReference {
            return SBASurveyLoader(surveyReference: surveyReference)
        } else if let resourceTransformer = activityReference.activityInfo?.resource {
            return resourceTransformer
        }

        // Next look for a moduleId.
        if let moduleId = activityReference.activityInfo?.moduleId,
            let transformer = self.instantiateTaskTransformer(for: moduleId) {
            return transformer
        }
        
        // Finally return a task from the task map (if found).
        if let task = self.task(for: activityReference) {
            return SBAConfigurationTaskTransformer(task: task)
        }
        
        return nil
    }
    
    /// Override this method to return a task transformer for a given task. This method is intended
    /// to be able to run active tasks such as "tapping" or "tremor" where the task module is described
    /// in another github repository.
    open func instantiateTaskTransformer(for moduleId: SBAModuleIdentifier) -> RSDTaskTransformer? {
        return moduleId.taskTransformer()
    }
    
    /// Override this method to return a task for a given activity reference. By default, this method will
    /// look in its task map for a task with a matching identifier.
    open func task(for activityReference: SBASingleActivityReference) -> RSDTask? {

        // Look for a mapped task identifier.
        let storedTask: RSDTask? = {
            if let task = self.taskMap[activityReference.identifier] {
                return task
            }
            else if let moduleId = activityReference.activityInfo?.moduleId ?? self.schemaIdentifierMap[activityReference.identifier],
                let task = self.taskMap[moduleId.stringValue] {
                return task
            }
            else {
                return nil
            }
        }()
        
        // Copy if option available.
        if let copyableTask = storedTask as? RSDCopyTask {
            return copyableTask.copy(with: activityReference.identifier, schemaInfo: activityReference.schemaInfo)
        } else {
            return storedTask
        }
    }
}

/// A light-weight pointer to a stored task.
class SBAConfigurationTaskTransformer : RSDTaskTransformer {
    let task: RSDTask
    init(task: RSDTask) {
        self.task = task
    }
    
    var estimatedFetchTime: TimeInterval {
        return 0
    }
    
    func fetchTask(with factory: RSDFactory, taskIdentifier: String, schemaInfo: RSDSchemaInfo?, callback: @escaping RSDTaskFetchCompletionHandler) {
        DispatchQueue.main.async {
            if let copyableTask = self.task as? RSDCopyTask {
                callback(taskIdentifier, copyableTask.copy(with: taskIdentifier, schemaInfo: schemaInfo), nil)
            } else {
                callback(taskIdentifier, self.task, nil)
            }
        }
    }
}


/// A protocol that can be used to filter and parse the scheduled activities for a
/// variety of customized UI/UX designs based on the objects defined in the
public protocol SBAActivityGroup : RSDTaskGroup {
    
    /// The text to display for the task group when displaying this in a list or
    /// collection where the format of the string is compact or extended, depending
    /// upon the requirements of the UI design.
    var journeyTitle: String? { get }
    
    /// A list of the activity identifiers associated with this task group.
    var activityIdentifiers : [RSDIdentifier] { get }
    
    /// An identifier that can be used to associate an `SBBScheduledActivity` instance
    /// with setting up a local reminder for when to perform a task.
    var notificationIdentifier : RSDIdentifier? { get }
    
    /// The schedule plan guid that can be used to map scheduled activities to
    /// the appropriate group in the case where more than one group may contain
    /// the same tasks.
    var schedulePlanGuid : String? { get }
}

extension SBAActivityGroup {
    
    /// Returns the configuration activity info objects mapped by activity identifier.
    public var tasks : [RSDTaskInfo] {
        let map = SBABridgeConfiguration.shared.activityInfoMap
        return self.activityIdentifiers.compactMap { map[$0.stringValue] }
    }
}

/// Extend the task info protocol to include optional pointers for use by an `SBBTaskReference`
/// as the source of a task transformer.
public protocol SBAActivityInfo : RSDTaskInfo {

    /// An optional resource for loading a task from a `SBBTaskReference` or `SBBSchemaReference`
    var resource: RSDResourceTransformerObject? { get }
    
    /// An optional string that can be used to identify an active task module such as a
    /// "tapping" task or "walkAndBalance" task.
    var moduleId: SBAModuleIdentifier?  { get }
}

// MARK: Codable implementation of the mapping objects.

/// `SBAActivityMappingObject` is a decodable instance of an activity mapping
/// that can be used to decode a Plist or JSON dictionary.
struct SBAActivityMappingObject : Decodable {
    let studyDuration : DateComponents?
    let groups : [SBAActivityGroupObject]?
    let activityList : [SBAActivityInfoObject]?
    let tasks : [RSDTaskObject]?
    let schemaIdentifierMap : [String : SBAModuleIdentifier]?
}

/// `SBAActivityGroupObject` is a `Decodable` implementation of a `SBAActivityGroup`.
///
/// - example:
/// ````
///    // Example activity group.
///    let json = """
///            {
///                "identifier": "foo",
///                "title": "Title",
///                "journeyTitle": "Journey title",
///                "detail": "A detail about the object",
///                "imageSource": "fooImage",
///                "activityIdentifiers": ["taskA", "taskB", "taskC"],
///                "notificationIdentifier": "scheduleFoo",
///                "schedulePlanGuid": "abcdef12-3456-7890"
///            }
///            """.data(using: .utf8)! // our data in native (JSON) format
/// ````
public struct SBAActivityGroupObject : Decodable, SBAOptionalImageVendor, SBAActivityGroup {

    /// A short string that uniquely identifies the task group.
    public let identifier: String
    
    /// The primary text to display for the task group in a localized string.
    public let title: String?
    
    /// Detail text information about the task group.
    public let detail: String?
    
    /// The text to display for the task group when displaying this in a list or
    /// collection where the format of the string is compact or extended, depending
    /// upon the requirements of the UI design.
    public let journeyTitle: String?
    
    /// An icon image that can be used for displaying the task group.
    public let imageSource: RSDImageWrapper?

    /// Use an image directly rather than an image wrapper.
    public private(set) var image : UIImage? = nil
    
    /// A list of the activity identifiers associated with this task group.
    public let activityIdentifiers : [RSDIdentifier]
    
    /// An identifier that can be used to associate an `SBBScheduledActivity` instance
    /// with setting up a local reminder for when to perform a task.
    public let notificationIdentifier : RSDIdentifier?
    
    /// The schedule plan guid that can be used to map scheduled activities to
    /// the appropriate group in the case where more than one group may contain
    /// the same tasks.
    public let schedulePlanGuid : String?
    
    private enum CodingKeys : String, CodingKey {
        case identifier, title, detail, journeyTitle, imageSource, activityIdentifiers, notificationIdentifier, schedulePlanGuid
    }
    
    /// Default initializer.
    public init(identifier: String,
                title: String?,
                journeyTitle: String?,
                image : UIImage?,
                activityIdentifiers : [RSDIdentifier],
                notificationIdentifier : RSDIdentifier?,
                schedulePlanGuid : String?) {
        self.identifier = identifier
        self.title = title
        self.journeyTitle = journeyTitle
        self.image = image
        self.activityIdentifiers = activityIdentifiers
        self.notificationIdentifier = notificationIdentifier
        self.schedulePlanGuid = schedulePlanGuid
        self.detail = nil
        self.imageSource = nil
    }
    
    /// Returns nil. This task group is intended to allow using a shared codable configuration
    /// and does not directly implement instantiating a task path.
    public func instantiateTaskPath(for taskInfo: RSDTaskInfo) -> RSDTaskPath? {
        return nil
    }
}

/// `SBAActivityInfoObject` is a `Decodable` implementation of a `SBAActivityInfo`.
///
/// - example:
/// ````
///    // Example JSON for a task that references a module id.
///    let json = """
///            {
///                "identifier": "foo",
///                "title": "Title",
///                "subtitle": "Subtitle",
///                "detail": "A detail about the object",
///                "imageSource": "fooImage",
///                "minuteDuration": 10,
///                "moduleId": "tapping"
///            }
///            """.data(using: .utf8)! // our data in native (JSON) format
///
///    // Example JSON for a task that references an embedded resource file.
///    let json = """
///            {
///                "identifier": "foo",
///                "title": "Title",
///                "subtitle": "Subtitle",
///                "detail": "A detail about the object",
///                "imageSource": "fooImage",
///                "minuteDuration": 10,
///                "resource": {   "resourceName" : "Foo_Task",
///                                "bundleIdentifier" : "org.example.Foo",
///                                "classType" : "FooTask"
///                            }
///            }
///            """.data(using: .utf8)! // our data in native (JSON) format
/// ````
public struct SBAActivityInfoObject : Decodable, SBAOptionalImageVendor, SBAActivityInfo {

    private enum CodingKeys : String, CodingKey {
        case identifier, title, subtitle, detail, _estimatedMinutes = "minuteDuration", imageSource, resource, moduleId
    }
    
    /// A short string that uniquely identifies the task.
    public let identifier : String
    
    /// The primary text to display for the task in a localized string.
    public var title : String?
    
    /// The subtitle text to display for the task in a localized string.
    public var subtitle : String?
    
    /// Additional detail text to display for the task. Generally, this would be displayed
    /// while the task is being fetched.
    public var detail : String?
    
    /// The estimated number of minutes that the task will take.
    public var estimatedMinutes: Int {
        return _estimatedMinutes ?? 0
    }
    private var _estimatedMinutes: Int?
    
    /// An optional resource for loading a task from a `SBBTaskReference` or `SBBSchemaReference`.
    public var resource: RSDResourceTransformerObject?
    
    /// An optional string that can be used to identify an active task module such as a
    /// "tapping" task or "walkAndBalance" task.
    public var moduleId: SBAModuleIdentifier?
    
    /// An icon image that can be used for displaying the task.
    public var imageSource : RSDImageWrapper?
    
    /// Use an image directly rather than an image wrapper.
    public var image : UIImage? = nil
    
    /// The schema info on this object is ignored.
    public var schemaInfo: RSDSchemaInfo? = nil
    
    /// The resource transformer points to the `resource`.
    public var resourceTransformer: RSDTaskTransformer? {
        return resource
    }
    
    public func copy(with identifier: String) -> SBAActivityInfoObject {
        var copy = SBAActivityInfoObject(identifier: identifier)
        copy.title = self.title
        copy.subtitle = self.subtitle
        copy.detail = self.detail
        copy._estimatedMinutes = self._estimatedMinutes
        copy.resource = self.resource
        copy.moduleId = self.moduleId
        copy.imageSource = self.imageSource
        copy.image = self.image
        copy.schemaInfo = self.schemaInfo
        return copy
    }
    
    public init(identifier : String) {
        self.identifier = identifier
    }
    
    /// Default initializer.
    public init(identifier : RSDIdentifier,
                title : String?,
                subtitle : String?,
                detail : String?,
                estimatedMinutes: Int?,
                iconImage : UIImage?,
                resource: RSDResourceTransformerObject?,
                moduleId: SBAModuleIdentifier?) {
        self.identifier = identifier.stringValue
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self._estimatedMinutes = estimatedMinutes
        self.image = iconImage
        self.resource = resource
        self.moduleId = moduleId
        self.imageSource = nil
    }
}

/// Convenience protocol to allow vending the image either from a `UIImage` *or* `RSDImageWrapper`.
public protocol SBAOptionalImageVendor {
    
    /// The image property is used if the  object is instantiated from within the app.
    var image : UIImage? { get }
    
    /// The image source is used if decoding the object.
    var imageSource : RSDImageWrapper? { get }
}

extension SBAOptionalImageVendor {

    /// Returns either the `iconImage` or `icon`
    public var imageVendor: RSDImageVendor? {
        return self.image ?? self.imageSource
    }
}
