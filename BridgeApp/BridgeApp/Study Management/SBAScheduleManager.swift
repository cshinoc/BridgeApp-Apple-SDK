//
//  SBAScheduleManager.swift
//  BridgeApp
//
//  Copyright © 2016-2018 Sage Bionetworks. All rights reserved.
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

extension Notification.Name {
    
    /// Notification name posted by the `SBAScheduleManager` when the activities have been updated.
    public static let SBAUpdatedScheduledActivities = Notification.Name(rawValue: "SBAUpdatedScheduledActivities")
    
    /// Notification name posted by the `SBAScheduleManager` when the activities did send an update
    /// of the scheduled activities to Bridge.
    public static let SBADidSendUpdatedScheduledActivities = Notification.Name(rawValue: "SBADidSendUpdatedScheduledActivities")
}

/// Default data source handler for scheduled activities. This manager is used to get `SBBScheduledActivity`
/// objects and upload the task results for Bridge services. By default, this manager will fetch all the
/// activities, but will *not* cache them all in memory. Instead, it will filter out those activites that are
/// valid for today and the most recent finished activity (if any) for each activity identifier where the
/// "activity identifier" refers to an `SBBActivity` object's associated `SBAActivityReference`.
///
open class SBAScheduleManager: NSObject, RSDDataArchiveManager {

    /// List of keys used in the notifications sent by this manager.
    public enum NotificationKey : String {
        case previousActivities, updatedActivities
    }
    
    public override init() {
        super.init()
        
        // Add an observer that the schedules have been updated from the server.
        NotificationCenter.default.addObserver(forName: .SBAFinishedUpdatingScheduleCache, object: nil, queue: .main) { (notification) in
            self.reloadData()
        }
        
        // Add an observer that a schedule manager has updated the scheduled activities. Often updating the
        // schedules will change the available "next" schedule.
        NotificationCenter.default.addObserver(forName: .SBADidSendUpdatedScheduledActivities, object: nil, queue: .main) { (notification) in
            if let schedules = notification.userInfo?[SBAScheduleManager.NotificationKey.updatedActivities] as? [SBBScheduledActivity],
                self.shouldReload(schedules: schedules) {
                self.reloadData()
            }
        }
        
        // load the activities from cache on init.
        self.loadScheduledActivities()
    }
    
    /// Should the schedules associated with this schedule manager be changed when a given schedule updates?
    /// By default this will return `true` if at least one of the schedules has been marked as completed
    /// and if there is an associated activity group, if at least one of the schedules is in this group.
    open func shouldReload(schedules: [SBBScheduledActivity]) -> Bool {
        guard let group = self.activityGroup else {
            return schedules.first(where: { $0.isCompleted }) != nil
        }
        let identifiers = group.activityIdentifiers.map { $0.stringValue }
        return schedules.first(where: {
            $0.activityIdentifier != nil &&
                identifiers.contains($0.activityIdentifier!) &&
                $0.isCompleted
        }) != nil
    }
    
    // MARK: Data source
    
    /// Add an identifier that can be used for mapping this schedule manager to the displayed schedules.
    open var identifier : String = "Today"

    /// This is an array of the activities fetched by the call to the server in `reloadData`. By default,
    /// this list includes the activities filtered using the `scheduleFilterPredicate`.
    @objc open var scheduledActivities: [SBBScheduledActivity] = []
    
    // MARK: Schedule loading and filtering
    
    /// The activity group associated with this schedule manager. If non-nil, this will be used in setting up
    /// the filtering predicates and finding the "most appropriate" schedule when creating a task path.
    /// This will get the activity group by getting the currently registered activity group from the shared
    /// configuration using `self.identifier` as the group identifier.
    open var activityGroup : SBAActivityGroup? {
        get {
            return SBABridgeConfiguration.shared.activityGroup(with: self.identifier)
        }
        set {
            guard let newGroup = newValue else { return }
            if SBABridgeConfiguration.shared.activityGroup(with: newGroup.identifier) == nil {
                SBABridgeConfiguration.shared.addMapping(with: newGroup)
            }
            self.identifier = newGroup.identifier
        }
    }
    
    /// Fetch request objects can be used to make compound fetch requests to retrieve schedules that match
    /// different sets of parameters. For example, a task group might be set up to group a set of tasks
    /// together where the schedule used to run a new task is different from the schedule used to mark it as
    /// finished. This allows for that more complicated logic.
    public struct FetchRequest {
        
        /// The predicate to use to filter the fetched results.
        public let predicate: NSPredicate
        
        /// The sort descriptors to use to sort the results.
        public let sortDescriptors: [NSSortDescriptor]?
        
        /// The maximum number of schedules to fetch in this request.
        public let fetchLimit: UInt?
        
        public init(predicate: NSPredicate, sortDescriptors: [NSSortDescriptor]?, fetchLimit: UInt?) {
            self.predicate = predicate
            self.sortDescriptors = sortDescriptors
            self.fetchLimit = fetchLimit
        }
    }
    
    /// The fetch requests to use to fetch the schedules associated with this manager. By default, if
    /// this schedule manager has an associated activity group, then this will return an array of the
    /// fetch requests for those schedules available today and the most recently finished schedule for each
    /// activity included in the group. Otherwise, a request will be created for all activities available
    /// today.
    open func fetchRequests() -> [FetchRequest] {
        if let group = activityGroup {
            
            // Default filtering if there is an associated activity group is to return the current schedules
            // (the ones that are valid *now*) and the most recent finished schedule (to allow for marking
            // the activity as "completed".
            
            // Get today's schedules.
            var requests: [FetchRequest] = []
            let todayPredicate = NSCompoundPredicate(andPredicateWithSubpredicates:
                    [self.availablePredicate(),
                     SBBScheduledActivity.activityGroupPredicate(for: group)])
            let todayRequest = FetchRequest(predicate: todayPredicate, sortDescriptors: nil, fetchLimit: nil)
            requests.append(todayRequest)
            
            // Add a request **for each** identifier to get the most recently finished schedule even if that
            // schedule is *not* part of this activity group.
            group.activityIdentifiers.forEach {
                let predicate = self.historyPredicate(for: $0)
                let sortDescriptors = [SBBScheduledActivity.finishedOnSortDescriptor(ascending: false)]
                requests.append(FetchRequest(predicate: predicate, sortDescriptors: sortDescriptors, fetchLimit: 1))
            }
            
            return requests
        }
        else {
            
            // If there is no activity group associated with this schedule then return all activities that
            // are valid today.
            return [FetchRequest(predicate: self.availablePredicate(), sortDescriptors: nil, fetchLimit: nil)]
        }
    }
    
    /// The predicate to use for filtering today's activities for those available today. If there is an
    /// `activityGroup` associated with this schedule manager, the fetch request for today's activities will
    /// be built using this predicate and the activity group predicate. Otherwise, only this predicate will
    /// be used. Default is to return `SBBScheduledActivity.availableTodayPredicate()`.
    open func availablePredicate() -> NSPredicate {
        return SBBScheduledActivity.availableTodayPredicate()
    }
    
    /// The predicate to use for filtering past activities. By default, this will return all activities where
    /// the `finishedOn` property is non-nil and the activity identifier matches the given value.
    /// - parameter activityIdentifier: The activity identifier for the schedule.
    /// - returns: The predicate for this fetch request.
    open func historyPredicate(for activityIdentifier: RSDIdentifier) -> NSPredicate {
        return NSCompoundPredicate(andPredicateWithSubpredicates:
            [SBBScheduledActivity.isFinishedPredicate(),
             SBBScheduledActivity.activityIdentifierPredicate(with: activityIdentifier.stringValue)])
    }
    
    /// State management for whether or not the schedules are reloading.
    public private(set) var isReloading: Bool = false
    
    /// A serial queue used to manage data crunching.
    public let offMainQueue = DispatchQueue(label: "org.sagebionetworks.BridgeApp.SBAScheduleManager")
    
    /// Reload the data by fetching changes to the scheduled activities.
    open func reloadData() {
        loadScheduledActivities()
    }
    
    /// Load the scheduled activities from cache using the `fetchRequests()` for this schedule manager.
    public final func loadScheduledActivities() {
        DispatchQueue.main.async {
            if self.isReloading { return }
            self.isReloading = true
            
            self.offMainQueue.async {
                do {
                
                    // Fetch the cached schedules.
                    let requests = self.fetchRequests()
                    var scheduleGuids: [String] = []
                    var schedules: [SBBScheduledActivity] = []
                    
                    try requests.forEach {
                        let fetchedSchedules = try self.getCachedSchedules(using: $0)
                        if schedules.count == 0 {
                            schedules = fetchedSchedules
                        }
                        else {
                            fetchedSchedules.forEach {
                                if !scheduleGuids.contains($0.guid) {
                                    scheduleGuids.append($0.guid)
                                    schedules.append($0)
                                }
                            }
                        }
                    }

                    DispatchQueue.main.async {
                        self.update(fetchedActivities: schedules)
                        self.isReloading = false
                    }
                }
                catch let error {
                    DispatchQueue.main.async {
                        self.updateFailed(error)
                        self.isReloading = false
                    }
                }
            }
        }
    }
    
    /// Add internal method for testing.
    internal func getCachedSchedules(using fetchRequest: FetchRequest) throws -> [SBBScheduledActivity] {
        return try BridgeSDK.activityManager.getCachedSchedules(using: fetchRequest.predicate,
                                                                sortDescriptors: fetchRequest.sortDescriptors,
                                                                fetchLimit: fetchRequest.fetchLimit ?? 0)
    }

    
    // MARK: Data handling
    
    /// Called on the main thread if updating the scheduled activities fails.
    open func updateFailed(_ error: Error) {
        debugPrint("WARNING: Failed to fetch cached schedules: \(error)")
    }
    
    /// Called on the main thread once Bridge returns the requested scheduled activities.
    ///
    /// - parameter scheduledActivities: The list of activities returned by the service.
    open func update(fetchedActivities: [SBBScheduledActivity]) {
        if (fetchedActivities != self.scheduledActivities) {
            self.scheduledActivities = fetchedActivities
            let previous = self.scheduledActivities
            self.didUpdateScheduledActivities(from: previous)
        }
    }
    
    /// Called when the schedules have changed.
    ///
    /// - parameter previousActivities: The schedules that were previously being stored in memory.
    open func didUpdateScheduledActivities(from previousActivities: [SBBScheduledActivity]) {
        
        // Post notification that the schedules were updated.
        NotificationCenter.default.post(name: .SBAUpdatedScheduledActivities,
                                        object: self,
                                        userInfo: [NotificationKey.previousActivities: previousActivities])
    }
    
    /// Sort the scheduled activities. By default this will sort by comparing the `scheduledOn` property.
    open func sortActivities(_ scheduledActivities: [SBBScheduledActivity]?) -> [SBBScheduledActivity]? {
        guard (scheduledActivities?.count ?? 0) > 0 else { return nil }
        return scheduledActivities!.sorted(by: { (scheduleA, scheduleB) -> Bool in
            return scheduleA.scheduledOn.compare(scheduleB.scheduledOn) == .orderedAscending
        })
    }
    
    
    // MARK: Schedule management
    
    /// If a schedule is unavailable, then the user is shown an alert explaining when it will become
    /// available.
    ///
    /// - parameter schedule: The schedule to check.
    /// - returns: The message to display in an alert for a schedule that is not currently available.
    open func messageForUnavailableSchedule(_ schedule: SBBScheduledActivity) -> String {
        var scheduledTime: String!
        if schedule.scheduledOn < Date().startOfDay().addingNumberOfDays(1) {
            scheduledTime = schedule.scheduledTime
        }
        else {
            scheduledTime = DateFormatter.localizedString(from: schedule.scheduledOn, dateStyle: .medium, timeStyle: .none)
        }
        return Localization.localizedStringWithFormatKey("ACTIVITY_SCHEDULE_MESSAGE_%@", scheduledTime)
    }
    
    /// Get the schema info associated with the given activity identifier. By default, this looks at the
    /// shared bridge configuration's schema reference map.
    open func schemaInfo(for activityIdentifier: String) -> RSDSchemaInfo? {
        return SBABridgeConfiguration.shared.schemaReferenceMap[activityIdentifier]
    }
    
    /// Get the task for this activity identifier. By default, this will query the bridge configuration.
    open func task(for activityIdentifier: String) -> RSDTask? {
        return SBABridgeConfiguration.shared.taskMap[activityIdentifier]
    }
    
    /// Get the scheduled activity that is associated with this schedule identifier and task result.
    ///
    /// For the case where this is a combo task that includes multiple schemas (for example, medication
    /// tracking and finger tapping) then we want to preference the schedule associated with the **schema**
    /// over the schedule that was used to trigger the task. The default behavior of this method, therefore
    /// is to look for a schema and return the schedule associated with that schema, if found.
    ///
    /// - parameters:
    ///     - taskResult: The task result for this task, subtask, or section.
    ///     - scheduleIdentifier: The schedule identifier that was used to start the task.
    /// - returns: The schedule associated with this task view controller (if found).
    open func scheduledActivity(for taskResult: RSDTaskResult, scheduleIdentifier: String?) -> SBBScheduledActivity? {
        
        let todayPredicate = SBBScheduledActivity.availableTodayPredicate()
        
        // Look for a schedule that matches the given scheduleIdentifier.
        let guidSchedule: SBBScheduledActivity? = {
            guard let scheduleGuid = scheduleIdentifier else { return nil }
            if let schedule = self.scheduledActivities.first(where: { $0.guid == scheduleGuid }) {
                return schedule
            }
            else {
                let activityGuid = SBBScheduledActivity.activityGuid(from: scheduleGuid)
                return self.scheduledActivities.rsd_last(where: {
                    $0.activity.guid == activityGuid && todayPredicate.evaluate(with: $0)
                })
            }
        }()
        
        // We only care about task results that have a matching schema otherwise, return the guid schedule.
        guard let schema = taskResult.schemaInfo ?? schemaInfo(for: taskResult.identifier),
            let schemaIdentifier = schema.schemaIdentifier else {
                return guidSchedule
        }
        
        // Look for a schedule that matches the given schema identifier.
        let schemaSchedule = self.scheduledActivities.rsd_last(where: {
            $0.activityIdentifier == schemaIdentifier &&
            todayPredicate.evaluate(with: $0)
        })
        
        // If the found schema-based schedule has the same activity guid as the guid-based schedule,
        // then return the guid schedule.
        if schemaSchedule == nil || schemaSchedule!.activity.guid == guidSchedule?.activity.guid {
            return guidSchedule
        }
        else {
            return schemaSchedule
        }
    }
    
    /// Is the given task info completed for the given date?
    open func isCompleted(for taskInfo: RSDTaskInfo, on date: Date) -> Bool {
        let taskPredicate = SBBScheduledActivity.activityIdentifierPredicate(with: taskInfo.identifier)
        let finishedPredicate = SBBScheduledActivity.finishedOnDatePredicate(on: date)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [taskPredicate, finishedPredicate])
        return self.scheduledActivities.first(where: { predicate.evaluate(with: $0) }) != nil
    }
    
    /// Get the scheduled activities associated with a given group that are available on a given day.
    /// The criteria for determining availablity is dependent upon the timing of the activity. For a
    /// day in the past, the criteria includes when the task was finished, expired, and scheduled. For
    /// a day in the future, the criterion is decided by when the activity is scheduled. For today, the
    /// activity must either be finished today, or available today (scheduled for a time window that
    /// includes this day.
    ///
    /// - parameters:
    ///     - activityGroup: The activity group to filter on.
    ///     - availableOn: The date for the day when the activities are "available".
    /// - returns: The schedule associated with this task view controller (if available).
    open func scheduledActivities(for activityGroup: SBAActivityGroup, availableOn: Date) -> [SBBScheduledActivity] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates:
            [SBBScheduledActivity.availableOnPredicate(on: availableOn),
             SBBScheduledActivity.activityGroupPredicate(for: activityGroup)])
        return self.scheduledActivities.filter { predicate.evaluate(with: $0) }
    }
    
    /// Instantiate a task path appropriate to the given task info. This method will attempt to map the
    /// task info to a schedule, but if called, it is assumed that even if there is no schedule associated
    /// with this task, that the task path should be instantiated.
    ///
    /// The returned result includes the instantiated task path, the reference schedule (if found), and the
    /// clientData from the most recent finished run of the schedule (if found).
    ///
    /// - note: This method should not be used to instantiate child task paths that are used to track the
    /// task state for a subtask. Instead, it is intended for starting a new task and will set up any state
    /// handling (such as tracking data groups) that must be managed globally.
    ///
    /// - parameters:
    ///     - taskInfo: The task info object to use to create the task path.
    ///     - activityGroup: The activity group to use to determine the schedule. This is used for the case
    ///                      where there may be multiple schedules with the same task and the
    ///                      `schedulePlanGUID` on the activity group is used to determine which available
    ///                      schedule is the one to associate with this task.
    /// - returns:
    ///     - taskPath: The instantiated task path.
    ///     - referenceSchedule: The schedule to reference for uploading the task path results (if any).
    ///     - clientData: The client data from the most recent finished run of the schedule (if any).
    open func instantiateTaskPath(for taskInfo: RSDTaskInfo, in activityGroup: SBAActivityGroup? = nil) -> (taskPath: RSDTaskPath, referenceSchedule: SBBScheduledActivity?, clientData: SBBJSONValue?) {
        
        // Set up predicates.
        var taskPredicate = SBBScheduledActivity.activityIdentifierPredicate(with: taskInfo.identifier)
        if let guid = (activityGroup ?? self.activityGroup)?.schedulePlanGuid(for: taskInfo.identifier) {
            taskPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                taskPredicate, SBBScheduledActivity.schedulePlanPredicate(with: guid)])
        }

        // Get the schedule.
        let todaySchedules = self.scheduledActivities.filter {
            taskPredicate.evaluate(with: $0) && (($0.scheduledOn.timeIntervalSinceNow < 0) && !$0.isExpired)
        }
        let schedule = todaySchedules.rsd_last(where: { $0.isCompleted == false }) ?? todaySchedules.last
        
        // Get the clientData from the most recent finished schedule with the same activity identifier.
        var clientData: SBBJSONValue?
        var currentFinishedOn = Date.distantPast
        let activityPredicate = SBBScheduledActivity.activityIdentifierPredicate(with: taskInfo.identifier)
        self.scheduledActivities.forEach { (schedule) in
            if let data = schedule.clientData,
                let finishedOn = schedule.finishedOn, finishedOn > currentFinishedOn,
                activityPredicate.evaluate(with: schedule) {
                clientData = data
                currentFinishedOn = finishedOn
            }
        }
        
        // Create the task path, by looking for a valid task transformer.
        let taskPath: RSDTaskPath
        if let activityReference = schedule?.activity.activityReference {
            if let taskInfoStep = activityReference as? RSDTaskInfoStep {
                taskPath = RSDTaskPath(taskInfo: taskInfoStep)
            }
            else {
                let taskInfoStep = RSDTaskInfoStepObject(with: activityReference)
                taskPath = RSDTaskPath(taskInfo: taskInfoStep)
            }
        }
        else if let task = self.task(for: taskInfo.identifier) {
            // Copy if option available.
            if let copyableTask = task as? RSDCopyTask,
                task.schemaInfo == nil,
                let schema = self.schemaInfo(for: taskInfo.identifier) {
                taskPath = RSDTaskPath(task: copyableTask.copy(with: taskInfo.identifier, schemaInfo: schema))
            }
            else {
                taskPath = RSDTaskPath(task: task)
            }
        }
        else if let _ = taskInfo.resourceTransformer {
            let taskInfoStep = RSDTaskInfoStepObject(with: taskInfo)
            taskPath = RSDTaskPath(taskInfo: taskInfoStep)
        }
        else {
            assertionFailure("Failed to instantiate the task for this task info.")
            let task = RSDTaskObject(identifier: taskInfo.identifier, stepNavigator: RSDConditionalStepNavigatorObject(with: []))
            taskPath = RSDTaskPath(task: task)
        }
        
        // Assign values to the task path from the schedule.
        taskPath.scheduleIdentifier = schedule?.guid
        
        // Set up the data groups tracking rule.
        if let participant = SBAParticipantManager.shared.studyParticipant {
            // If there is an existing tracking rule then there was a task that wasn't
            // saved. So these changes should **not** be commited. Throw them out.
            SBAFactory.shared.trackingRules.remove(where: { $0 is DataGroupsTrackingRule})
            let rule = DataGroupsTrackingRule(initialCohorts: participant.dataGroups ?? [])
            SBAFactory.shared.trackingRules.append(rule)
        } else {
            debugPrint("WARNING: Missing a study particpant. Cannot get the data groups.")
        }
        
        return (taskPath, schedule, clientData)
    }
    
    /// Subclass the cohorts tracking rule so that we can use casting to check for an existing
    /// tracking rule.
    class DataGroupsTrackingRule : RSDCohortTrackingRule {
    }
    
    // MARK: RSDTaskViewControllerDelegate
    
    /// Call from the view controller that is used to display the task when the task is finished.
    ///
    /// - note: This method does not dismiss the task.
    open func taskController(_ taskController: RSDTaskController, didFinishWith reason: RSDTaskFinishReason, error: Error?) {
        if reason != .completed {
            // If the task finished with an error or discarded results, then delete the output directory.
            taskController.taskPath.deleteOutputDirectory()
            if let err = error {
                print("WARNING! Task failed: \(err)")
            }
        }
    }
    
    /// Call from the view controller that is used to display the task when the task is ready to save.
    open func taskController(_ taskController: RSDTaskController, readyToSave taskPath: RSDTaskPath) {
        
        // Archive and upload results. This is run on a background queue.
        taskPath.archiveResults(with: self) {
            // TODO: Implement completion handling if any?? syoung 05/24/2018
        }
        
        // Update the schedule on the server but only if the survey was not ended early
        if !taskPath.didExitEarly {
            self.offMainQueue.async {
                self.updateDataGroups(for: taskPath)
                self.updateSchedules(for: taskPath)
            }
        }
    }
    
    /// Do nothing.
    open func taskController(_ taskController: RSDTaskController, asyncActionControllerFor configuration: RSDAsyncActionConfiguration) -> RSDAsyncActionController? {
        return nil
    }
    
    // MARK: Upload to server
    
    /// Update the data groups. By default, this will look for changes on the shared `DataGroupsTrackingRule`.
    open func updateDataGroups(for taskPath: RSDTaskPath) {
        let rules = SBAFactory.shared.trackingRules.remove(where: { $0 is DataGroupsTrackingRule})
        guard let rule = rules.first as? DataGroupsTrackingRule,
            rule.initialCohorts != rule.currentCohorts
            else {
                return
        }
        
        BridgeSDK.participantManager.updateDataGroups(withGroups: rule.currentCohorts) { (_, error) in
            if let err = error {
                print("WARNING! Failed to update the data groups: \(err)")
            }
        }
    }
    
    /// Update the values on the scheduled activity. By default, this will recurse through the task path
    /// and it's children, looking for a schedule associated with the subtask path.
    open func updateSchedules(for taskPath: RSDTaskPath) {
        guard taskPath.parentPath == nil else {
            assertionFailure("This method should **only** be called for the top-level task path.")
            return
        }
        
        // Recursively get and update all the schedules in this task path.
        var schedules = [SBBScheduledActivity]()
        func appendSchedule(for path: RSDTaskPath) {
            guard let schedule = self.getAndUpdateSchedule(for: path) else {
                return
            }
            schedules.append(schedule)
            path.childPaths.enumerated().forEach {
                appendSchedule(for: $0.element.value)
            }
        }
        appendSchedule(for: taskPath)

        self.sendUpdated(for: schedules)
    }
    
    /// For each schedule that this task modifies, mark it as completed.
    ///
    /// - note: Override this method to add custom `clientData` objects to the schedule.
    open func getAndUpdateSchedule(for taskPath: RSDTaskPath) -> SBBScheduledActivity? {
        guard let schedule = self.scheduledActivity(for: taskPath.result, scheduleIdentifier: taskPath.scheduleIdentifier)
            else {
                return nil
        }
        
        schedule.startedOn = taskPath.result.startDate
        schedule.finishedOn = taskPath.result.endDate
        return schedule
    }
    
    /// Send message to Bridge server to update the given schedules. This includes both the task
    /// that was completed and any tasks that were performed as a requirement of completion of the
    /// primary task (such as a required one-time survey).
    open func sendUpdated(for schedules: [SBBScheduledActivity]) {
        
        // Post message to self that the scheduled activities were updated.
        self.didUpdateScheduledActivities(from: self.scheduledActivities)
        
        BridgeSDK.activityManager.updateScheduledActivities(schedules) { (_, _) in
            // Post notification that the schedules were updated.
            NotificationCenter.default.post(name: .SBADidSendUpdatedScheduledActivities,
                                            object: self,
                                            userInfo: [NotificationKey.updatedActivities : schedules])
        }
    }
    
    
    // MARK: RSDDataArchiveManager
    
    /// Should the task result archiving be continued if there was an error adding data to the current
    /// archive? Default behavior is to flush the archive and then return `false`.
    ///
    /// - parameters:
    ///     - archive: The current archive being built.
    ///     - error: The encoding error that was thrown.
    /// - returns: Whether or not archiving should continue. Default = `false`.
    open func shouldContinueOnFail(for archive: RSDDataArchive, error: Error) -> Bool {
        debugPrint("ERROR! Failed to archive results: \(error)")
        // Flush the archive.
        (archive as? SBBDataArchive)?.remove()
        return false
    }
    
    /// When archiving a task result, it is possible that the results of a task need to be split into
    /// multiple archives; for example, when combining two or more activities within the same task. If the
    /// task result components should be added to the current archive, then the manager should return
    /// `currentArchive` as the response. If the task result *for this section* should be ignored, then the
    /// manager should return `nil`. This allows the application to only upload data that is needed by the
    /// study, and not include information that is ignored by *this* study, but may be of interest to other
    /// researchers using the same task protocol.
    open func dataArchiver(for taskResult: RSDTaskResult, scheduleIdentifier: String?, currentArchive: RSDDataArchive?) -> RSDDataArchive? {

        // Look for a schema info associated with this portion of the task result. If not found, then
        // return the current archive.
        let schema = taskResult.schemaInfo ?? self.schemaInfo(for: taskResult.identifier)
        guard (currentArchive == nil) || (schema != nil) else {
            return currentArchive
        }
        
        let schemaInfo = schema ?? RSDSchemaInfoObject(identifier: taskResult.identifier, revision: 1)
        let archiveIdentifier = schemaInfo.schemaIdentifier ?? taskResult.identifier
        let schedule = self.scheduledActivity(for: taskResult, scheduleIdentifier: scheduleIdentifier)
        
        if let inputArchive = currentArchive as? SBAScheduledActivityArchive,
            ((inputArchive.identifier == archiveIdentifier) ||
             (inputArchive.schedule?.activity.guid == schedule?.activity.guid)) {
            // If the identifiers or activity guids are the same, then return the current archive.
            return inputArchive
        }
        else {
            // Create a new archive.
            return SBAScheduledActivityArchive(identifier: archiveIdentifier, schemaInfo: schemaInfo, schedule: schedule)
        }
    }
    
    /// Finalize the upload of all the created archives.
    public func encryptAndUpload(taskPath: RSDTaskPath, dataArchives: [RSDDataArchive], completion: @escaping (() -> Void)) {
        #if DEBUG
        dataArchives.forEach {
            guard let archive = $0 as? SBAScheduledActivityArchive else { return }
            self.copyTestArchive(archive: archive)
        }
        #endif
        let archives = dataArchives.compactMap { $0 as? SBBDataArchive }
        SBBDataArchive.encryptAndUploadArchives(archives)
        completion()
    }
    
    /// By default, if an archive fails, the error is printed and that's all that is done.
    open func handleArchiveFailure(taskPath: RSDTaskPath, error: Error, completion: @escaping (() -> Void)) {
        debugPrint("WARNING! Failed to archive \(taskPath.identifier). \(error)")
        completion()
    }
    
    #if DEBUG
    private func copyTestArchive(archive: SBAScheduledActivityArchive) {
        guard SBAParticipantManager.shared.isTestUser else { return }
        do {
            if !archive.isCompleted {
                try archive.complete()
            }
            let fileManager = FileManager.default
            
            let outputDirectory = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dirURL = outputDirectory.appendingPathComponent("archives", isDirectory: true)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
            
            // Scrub non-alphanumeric characters from the identifer
            var characterSet = CharacterSet.alphanumerics
            characterSet.invert()
            var filename = archive.identifier
            while let range = filename.rangeOfCharacter(from: characterSet) {
                filename.removeSubrange(range)
            }
            filename.append("-")
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HHmm"
            let dateString = dateFormatter.string(from: Date())
            filename.append(dateString)
            let debugURL = dirURL.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("zip")
            try fileManager.copyItem(at: archive.unencryptedURL, to: debugURL)
            debugPrint("Copied archive to \(debugURL)")
            
        } catch let err {
            debugPrint("Failed to copy archive: \(err)")
        }
    }
    #endif
}


