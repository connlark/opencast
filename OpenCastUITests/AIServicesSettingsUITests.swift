import XCTest

/// Settings › AI Services, the provider key sheet, the provider pickers, the
/// one-time key notice before Detect Ads and Generate, and the key screen.
/// Every key here is a fixture assembled from parts (the app's seams use the
/// same strings), never a real key.
final class AIServicesSettingsUITests: XCTestCase {
    private static let googleFixtureKey = ["AIza", "FixtureKeyForUITestsOnly", "00000000000"].joined()
    private static let openAIFixtureKey = ["sk-", "fixture-", "uitests-only-0123456789"].joined()
    private static let seededEpisodeRowIdentifier = "episode-row-ui-test-episode-1"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Screen

    @MainActor
    func testAIServicesProviderRowsShowEachKeyStatus() throws {
        let synced = makeApp(seedsGoogleKey: true, seedsOpenAIKey: true)
        synced.launch()
        openSettingsScreen("AI Services", in: synced)
        assertProviderRow("google", reads: "Key saved, synced", in: synced)
        assertProviderRow("openai", reads: "Key saved, synced", in: synced)
        assertDoesNotExist(
            synced.descendants(matching: .any)["AI Services Notice Row"],
            named: "notice row with a saved key"
        )
        attachSmokeScreenshot(named: "ai_services_both_keys_synced")
        assertHubRow(reads: "Key saved", in: synced)
        synced.terminate()

        let local = makeApp(seedsGoogleKey: true, seedsKeysLocalOnly: true)
        local.launch()
        openSettingsScreen("AI Services", in: local)
        assertProviderRow("google", reads: "Key saved, this device only", in: local)
        assertProviderRow("openai", reads: "No key", in: local)
        attachSmokeScreenshot(named: "ai_services_google_key_this_device")
    }

    @MainActor
    func testAIServicesKeySheetTestsSavesAndRemovesAKey() throws {
        let app = makeApp()
        app.launch()
        assertHubRow(reads: "No key", in: app)
        openSettingsScreen("AI Services", in: app)
        assertExists(
            app.descendants(matching: .any)["AI Services Notice Row"],
            named: "notice row without a key"
        )
        assertProviderRow("google", reads: "No key", in: app)
        attachSmokeScreenshot(named: "ai_services_no_keys")

        openKeySheet("google", title: "Google Gemini", in: app)
        let save = app.buttons["AI Services Save Key"]
        let test = app.buttons["AI Services Test Key"]
        XCTAssertFalse(save.isEnabled, "Save needs a typed key")
        XCTAssertFalse(test.isEnabled, "Test needs a typed or saved key")
        assertDoesNotExist(app.buttons["AI Services Remove Key"], named: "Remove Key without a saved key")
        assertExists(app.buttons["AI Services Get Key"], named: "Get a key from Google")

        typeKey(Self.googleFixtureKey, in: app)
        attachSmokeScreenshot(named: "ai_services_key_sheet_typed")
        assertNoFragment(of: Self.googleFixtureKey, in: app)
        XCTAssertTrue(save.isEnabled, "Save is offered for a whole typed key")

        test.tap()
        assertTestResult("Key works", in: app)
        assertNoFragment(of: Self.googleFixtureKey, in: app)

        // A passing test saves nothing: cancel, and the key is not stored.
        app.buttons["AI Services Cancel"].tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Cancel", timeout: 5)
        assertProviderRow("google", reads: "No key", in: app)
        openKeySheet("google", title: "Google Gemini", in: app)
        XCTAssertFalse(test.isEnabled, "Cancel cleared the typed key, and nothing was saved")
        typeKey(Self.googleFixtureKey, in: app)

        save.tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Save", timeout: 5)
        assertProviderRow("google", reads: "Key saved, synced", in: app)
        assertDoesNotExist(
            app.descendants(matching: .any)["AI Services Notice Row"],
            named: "notice row after saving a key"
        )
        assertNoFragment(of: Self.googleFixtureKey, in: app)
        attachSmokeScreenshot(named: "ai_services_google_key_saved")

        openKeySheet("google", title: "Google Gemini", in: app)
        let remove = app.buttons["AI Services Remove Key"]
        scrollUntilHittable(remove, in: app)
        remove.tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Remove Key", "AI Services Remove Key")
        ).firstMatch
        assertHittable(confirm, named: "Remove Key confirmation")
        attachSmokeScreenshot(named: "ai_services_remove_key_confirmation")
        confirm.tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Remove", timeout: 5)
        assertProviderRow("google", reads: "No key", in: app)
    }

    @MainActor
    func testAIServicesKeyTestShowsRejectedAndBillingResults() throws {
        for (stub, message) in [
            ("invalid_key", "Key not accepted"),
            ("billing_or_quota", "Your Google account needs billing or quota enabled")
        ] {
            let app = makeApp(keyTestResult: stub)
            app.launch()
            openSettingsScreen("AI Services", in: app)
            openKeySheet("google", title: "Google Gemini", in: app)
            typeKey(Self.googleFixtureKey, in: app)
            app.buttons["AI Services Test Key"].tap()
            assertTestResult(message, in: app)
            attachSmokeScreenshot(named: "ai_services_key_test_\(stub)")

            // A test never saves the key.
            app.buttons["AI Services Cancel"].tap()
            assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Cancel", timeout: 5)
            assertProviderRow("google", reads: "No key", in: app)
            assertNoFragment(of: Self.googleFixtureKey, in: app)
            app.terminate()
        }
    }

    /// The key test answers 2.5 s after it starts; a result that arrives
    /// after the draft it tested changed (an edit, the sync switch, Save,
    /// Remove, or the sheet closing and reopening) never shows.
    @MainActor
    func testAIServicesKeyTestResultNeverOutlivesItsDraft() throws {
        let app = makeApp(keyTestDelayMilliseconds: 2500)
        app.launch()
        openSettingsScreen("AI Services", in: app)
        openKeySheet("google", title: "Google Gemini", in: app)
        let test = app.buttons["AI Services Test Key"]
        let result = app.descendants(matching: .any)["AI Services Test Result"]
        typeKey(Self.googleFixtureKey, in: app)

        test.tap()
        typeKey("0", in: app)
        XCTAssertFalse(result.waitForExistence(timeout: 4), "A result for the edited draft should never show")

        test.tap()
        tapToggle(app.switches["AI Services Sync Toggle"], to: false)
        XCTAssertFalse(result.waitForExistence(timeout: 4), "A result from before the switch moved should never show")

        test.tap()
        app.buttons["AI Services Cancel"].tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Cancel", timeout: 5)
        openKeySheet("google", title: "Google Gemini", in: app)
        XCTAssertFalse(result.waitForExistence(timeout: 4), "A result from a closed sheet should never show")

        typeKey(Self.googleFixtureKey, in: app)
        test.tap()
        assertTestResult("Key works", in: app)

        test.tap()
        app.buttons["AI Services Save Key"].tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Save", timeout: 5)
        assertProviderRow("google", reads: "Key saved, synced", in: app)
        openKeySheet("google", title: "Google Gemini", in: app)
        XCTAssertFalse(result.waitForExistence(timeout: 4), "A result from before Save should never show")

        // With the field empty, Test checks the saved key.
        test.tap()
        let remove = app.buttons["AI Services Remove Key"]
        scrollUntilHittable(remove, in: app)
        remove.tap()
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Remove Key", "AI Services Remove Key")
        ).firstMatch
        assertHittable(confirm, named: "Remove Key confirmation")
        confirm.tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Remove", timeout: 5)
        assertProviderRow("google", reads: "No key", in: app)
        openKeySheet("google", title: "Google Gemini", in: app)
        XCTAssertFalse(result.waitForExistence(timeout: 4), "A result from before Remove should never show")
    }

    /// Every key test waits until this test releases it: an older request
    /// released after a newer one answered, or after its sheet closed and
    /// reopened, never shows.
    @MainActor
    func testAIServicesLateKeyTestResultsNeverShow() throws {
        let app = makeApp(keyTestResult: "invalid_key,accepted,billing_or_quota", gatesKeyTest: true)
        app.launch()
        openSettingsScreen("AI Services", in: app)
        openKeySheet("google", title: "Google Gemini", in: app)
        let test = app.buttons["AI Services Test Key"]
        let result = app.descendants(matching: .any)["AI Services Test Result"]
        typeKey(Self.googleFixtureKey, in: app)

        test.tap()
        typeKey("0", in: app)
        test.tap()
        releaseKeyTest(call: 2)
        assertTestResult("Key works", in: app)
        releaseKeyTest(call: 1)
        let olderAnswer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Key not accepted")).firstMatch
        XCTAssertFalse(olderAnswer.waitForExistence(timeout: 3), "The older request's answer should never show")
        assertTestResult("Key works", in: app)

        test.tap()
        app.buttons["AI Services Cancel"].tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Cancel", timeout: 5)
        openKeySheet("google", title: "Google Gemini", in: app)
        releaseKeyTest(call: 3)
        XCTAssertFalse(result.waitForExistence(timeout: 3), "A request from the closed sheet should never answer in the reopened one")
    }

    /// Turning sync off whose delete of the synced copy fails keeps the key
    /// here and says what remains; a replacement key whose write then fails
    /// stays typed; the synced copy beside the local key is offered for
    /// removal, behind a confirmation, until it is gone.
    @MainActor
    func testAIServicesRemovesASyncedCopyBesideTheLocalKey() throws {
        let app = makeApp(seedsGoogleKey: true, keyFaults: "delete-synced,update-local,delete-synced")
        app.launch()
        openSettingsScreen("AI Services", in: app)
        assertProviderRow("google", reads: "Key saved, synced", in: app)
        openKeySheet("google", title: "Google Gemini", in: app)
        let save = app.buttons["AI Services Save Key"]

        tapToggle(app.switches["AI Services Sync Toggle"], to: false)
        save.tap()
        assertExists(
            app.staticTexts["The key is saved on this device, but the synced copy couldn't be removed from your other devices."],
            named: "the incomplete sync-off message"
        )
        let removeCopy = app.buttons["AI Services Remove Synced Copy"]
        assertHittable(removeCopy, named: "Remove synced copy")
        XCTAssertFalse(save.isEnabled, "Save has nothing left to save")
        attachSmokeScreenshot(named: "ai_services_synced_copy_beside_local_key")

        typeKey(Self.googleFixtureKey, in: app)
        save.tap()
        assertExists(app.staticTexts["The key couldn't be saved. Try again."], named: "the failed replacement message")
        XCTAssertTrue(save.isEnabled, "The replacement key stays typed after its write failed")

        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Remove synced copy", "AI Services Remove Synced Copy")
        ).firstMatch
        scrollUntilHittable(removeCopy, in: app)
        removeCopy.tap()
        assertHittable(confirm, named: "Remove synced copy confirmation")
        attachSmokeScreenshot(named: "ai_services_remove_synced_copy_confirmation")
        confirm.tap()
        assertExists(app.staticTexts["The synced copy couldn't be removed. Try again."], named: "the failed removal message")

        scrollUntilHittable(removeCopy, in: app)
        removeCopy.tap()
        assertHittable(confirm, named: "Remove synced copy confirmation, again")
        confirm.tap()
        assertDoesNotExist(removeCopy, named: "the row once the synced copy is gone", timeout: 5)

        app.buttons["AI Services Cancel"].tap()
        assertDoesNotExist(app.navigationBars["Google Gemini"], named: "key sheet after Cancel", timeout: 5)
        assertProviderRow("google", reads: "Key saved, this device only", in: app)
    }

    @MainActor
    func testAIServicesSyncToggleChangesTheStatusAfterSave() throws {
        let app = makeApp(seedsOpenAIKey: true)
        app.launch()
        openSettingsScreen("AI Services", in: app)
        assertProviderRow("openai", reads: "Key saved, synced", in: app)

        openKeySheet("openai", title: "OpenAI", in: app)
        let sync = app.switches["AI Services Sync Toggle"]
        let save = app.buttons["AI Services Save Key"]
        assertToggle(sync, isOn: true)
        XCTAssertFalse(save.isEnabled, "Save needs a change")
        // The saved key is never shown, not even in the sheet that edits it.
        assertNoFragment(of: Self.openAIFixtureKey, in: app)
        tapToggle(sync, to: false)
        XCTAssertTrue(save.isEnabled, "Save is offered for a changed sync choice")
        attachSmokeScreenshot(named: "ai_services_sync_off")
        save.tap()
        assertDoesNotExist(app.navigationBars["OpenAI"], named: "key sheet after Save", timeout: 5)
        assertProviderRow("openai", reads: "Key saved, this device only", in: app)

        openKeySheet("openai", title: "OpenAI", in: app)
        assertToggle(sync, isOn: false)
        tapToggle(sync, to: true)
        save.tap()
        assertDoesNotExist(app.navigationBars["OpenAI"], named: "key sheet after Save", timeout: 5)
        assertProviderRow("openai", reads: "Key saved, synced", in: app)
    }

    @MainActor
    func testAIServicesPickersOfferOnlyEligibleProviders() throws {
        let both = makeApp(seedsGoogleKey: true, seedsOpenAIKey: true, policyVariant: "no-openai-chapters")
        both.launch()
        openSettingsScreen("AI Services", in: both)
        let adDetection = picker("ad_detection", in: both)
        assertPickerValue(adDetection, beginsWith: "Gemini")
        openPicker(adDetection, in: both)
        assertExists(menuOption(beginningWith: "Gemini", in: both), named: "Gemini option for ad detection")
        let gpt = menuOption(beginningWith: "GPT", in: both)
        assertHittable(gpt, named: "GPT option for ad detection")
        attachSmokeScreenshot(named: "ai_services_ad_detection_picker_both")
        gpt.tap()
        assertDoesNotExist(gpt, named: "ad detection menu after choosing", timeout: 5)
        assertPickerValue(adDetection, beginsWith: "GPT")

        let chapters = picker("chapters_summary", in: both)
        assertPickerValue(chapters, beginsWith: "Gemini")
        openPicker(chapters, in: both)
        let gemini = menuOption(beginningWith: "Gemini", in: both)
        assertHittable(gemini, named: "Gemini option for Chapters & Summary")
        assertDoesNotExist(menuOption(beginningWith: "GPT", in: both), named: "GPT option for Chapters & Summary")
        attachSmokeScreenshot(named: "ai_services_chapters_picker_no_openai_entry")
        gemini.tap()
        both.terminate()

        let googleOnly = makeApp(seedsGoogleKey: true)
        googleOnly.launch()
        openSettingsScreen("AI Services", in: googleOnly)
        let googleOnlyAdDetection = picker("ad_detection", in: googleOnly)
        assertPickerValue(googleOnlyAdDetection, beginsWith: "Gemini")
        openPicker(googleOnlyAdDetection, in: googleOnly)
        let onlyGemini = menuOption(beginningWith: "Gemini", in: googleOnly)
        assertHittable(onlyGemini, named: "Gemini option with only a Google key")
        assertDoesNotExist(menuOption(beginningWith: "GPT", in: googleOnly), named: "GPT option without an OpenAI key")
        onlyGemini.tap()
    }

    // MARK: Notice and key screen

    @MainActor
    func testAnalysisKeyNoticeShowsOnceBeforeMakeAdFree() throws {
        let app = makeApp(seedsLibrary: true, forcesKeyNotice: true)
        // Remote surfaces on: the first Detect Ads tap asks cloud or device,
        // which shows that the held tap ran.
        app.launchArguments.append("-OPENCAST_REMOTE_TRANSCRIPTION_DEV")
        app.launch()
        openSeededEpisodeDetail(in: app)

        let makeAdFree = app.buttons["Make Ad-Free"]
        assertHittable(makeAdFree, named: "Make Ad-Free")
        makeAdFree.tap()
        let later = app.buttons["AI Key Notice Later"]
        assertHittable(later, named: "notice Later button", timeout: 10)
        assertExists(app.buttons["AI Key Notice Add Key"], named: "notice Add a key button")
        assertDoesNotExist(app.buttons["Detect On This Device"], named: "mode dialog while the notice holds the tap")
        attachSmokeScreenshot(named: "analysis_key_notice")

        later.tap()
        assertDoesNotExist(later, named: "notice after Later", timeout: 5)
        assertExists(app.buttons["Detect On This Device"], named: "mode dialog after Later", timeout: 10)
        dismissDialog(in: app)
        assertDoesNotExist(app.buttons["Detect On This Device"], named: "mode dialog after dismissal", timeout: 5)

        assertHittable(makeAdFree, named: "Make Ad-Free for the second tap")
        makeAdFree.tap()
        assertExists(app.buttons["Detect On This Device"], named: "mode dialog on the second tap", timeout: 10)
        XCTAssertFalse(app.buttons["AI Key Notice Later"].exists, "The notice shows once")
    }

    @MainActor
    func testAnalysisKeyNoticeAddKeyFromGenerateOpensAIServices() throws {
        // Generate is offered from the route (the trial, seeded with units
        // left); Add a key never runs it.
        let app = makeApp(
            trialStatus: "units-left-3",
            seedsLibrary: true,
            seedsCompletedTranscript: true,
            forcesKeyNotice: true
        )
        app.launch()
        openSeededEpisodeDetail(in: app)

        let generate = app.buttons["Generate Chapters & Summary"]
        scrollUntilHittable(generate, in: app, maxSwipes: 8)
        generate.tap()
        let addKey = app.buttons["AI Key Notice Add Key"]
        assertHittable(addKey, named: "notice Add a key button", timeout: 10)
        attachSmokeScreenshot(named: "analysis_key_notice_generate")
        addKey.tap()

        assertExists(app.navigationBars["AI Services"], named: "AI Services after Add a key", timeout: 10)
        assertDoesNotExist(
            app.staticTexts["Generate Chapters & Summary?"],
            named: "generate disclosure after Add a key"
        )
        attachSmokeScreenshot(named: "analysis_key_notice_opened_ai_services")
    }

    @MainActor
    func testAnalysisKeyRequiredScreenOpensAIServices() throws {
        let app = makeApp(trialStatus: "exhausted", presentsKeyRequiredFor: "ad_detection")
        app.launch()

        let openSettings = app.buttons["Analysis Key Required Open Settings"]
        assertHittable(openSettings, named: "key screen Open Settings", timeout: 10)
        assertExists(app.buttons["Analysis Key Required Not Now"], named: "key screen Not now")
        assertExists(app.staticTexts["Add a key to keep going"], named: "key screen title")
        assertExists(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Your 5 free analyses are used.")
            ).firstMatch,
            named: "key screen body with the trial's 5 analyses"
        )
        attachSmokeScreenshot(named: "analysis_key_required_exhausted")

        openSettings.tap()
        assertExists(app.navigationBars["AI Services"], named: "AI Services from the key screen", timeout: 10)
        assertDoesNotExist(openSettings, named: "key screen after Open Settings", timeout: 5)
    }

    // MARK: Launcher

    @MainActor
    private func makeApp(
        seedsGoogleKey: Bool = false,
        seedsOpenAIKey: Bool = false,
        seedsKeysLocalOnly: Bool = false,
        policyVariant: String? = nil,
        trialStatus: String? = nil,
        keyTestResult: String? = nil,
        keyTestDelayMilliseconds: Int? = nil,
        gatesKeyTest: Bool = false,
        keyFaults: String? = nil,
        presentsKeyRequiredFor feature: String? = nil,
        seedsLibrary: Bool = false,
        seedsCompletedTranscript: Bool = false,
        forcesKeyNotice: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--opencast-ui-testing", "--opencast-force-dark-mode"]
        app.launchEnvironment["OPENCAST_UI_TESTING"] = "1"
        app.launchEnvironment["OPENCAST_FORCE_DARK_MODE"] = "1"
        if seedsLibrary {
            app.launchArguments.append("--opencast-seed-ui-library")
            app.launchEnvironment["OPENCAST_SEED_UI_LIBRARY"] = "1"
        }
        if seedsCompletedTranscript {
            app.launchArguments.append("--opencast-seed-completed-transcript")
            app.launchEnvironment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] = "1"
        }
        if seedsGoogleKey {
            app.launchArguments.append("--opencast-seed-analysis-key-google")
        }
        if seedsOpenAIKey {
            app.launchArguments.append("--opencast-seed-analysis-key-openai")
        }
        if seedsKeysLocalOnly {
            app.launchArguments.append("--opencast-seed-analysis-keys-local-only")
        }
        if let policyVariant {
            app.launchArguments.append("--opencast-seed-analysis-policy=\(policyVariant)")
        }
        if let trialStatus {
            app.launchArguments.append("--opencast-seed-analysis-trial=\(trialStatus)")
        }
        if let keyTestResult {
            app.launchArguments.append("--opencast-seed-analysis-key-test=\(keyTestResult)")
        }
        if let keyTestDelayMilliseconds {
            app.launchArguments.append("--opencast-seed-analysis-key-test-delay-ms=\(keyTestDelayMilliseconds)")
        }
        if gatesKeyTest {
            app.launchArguments.append("--opencast-seed-analysis-key-test-gated")
        }
        if let keyFaults {
            app.launchArguments.append("--opencast-seed-analysis-key-faults=\(keyFaults)")
        }
        if let feature {
            app.launchArguments.append("--opencast-present-analysis-key-required=\(feature)")
        }
        if forcesKeyNotice {
            app.launchArguments.append("--opencast-force-analysis-key-notice")
        }
        return app
    }

    // MARK: Helpers

    /// Lets the app's held key test number `call` (1 is the launch's first)
    /// answer: the app listens for this Darwin notification under the gated
    /// key-test seam.
    private func releaseKeyTest(call: Int) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.connor.opencast.ui-testing.release-analysis-key-test.\(call)" as CFString),
            nil,
            nil,
            true
        )
    }

    @MainActor
    private func providerRow(_ provider: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["AI Services Provider \(provider)"].firstMatch
    }

    @MainActor
    private func assertProviderRow(
        _ provider: String,
        reads status: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = providerRow(provider, in: app)
        assertExists(row, named: "\(provider) key row", file: file, line: line)
        let matches = NSPredicate(format: "value == %@", status)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: row)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "\(provider) row should read \(status), read \(row.value as? String ?? "nil")",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertHubRow(
        reads value: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openSection("Settings", in: app, file: file, line: line)
        let row = app.buttons["Settings Row AI Services"].firstMatch
        scrollUntilHittable(row, in: app, file: file, line: line)
        let rowValue = row.value as? String ?? ""
        XCTAssertTrue(
            row.label.contains(value) || rowValue.contains(value),
            "AI Services hub row should read \(value), read \(row.label) / \(rowValue)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func openKeySheet(
        _ provider: String,
        title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = providerRow(provider, in: app)
        assertHittable(row, named: "\(provider) key row", file: file, line: line)
        row.tap()
        assertExists(app.navigationBars[title], named: "\(title) key sheet", timeout: 5, file: file, line: line)
    }

    /// One `typeText` call: per-character typing on the simulator bounces
    /// the software keyboard.
    @MainActor
    private func typeKey(_ key: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.secureTextFields["AI Services Key Field"]
        assertHittable(field, named: "key field", file: file, line: line)
        field.tap()
        field.typeText(key)
    }

    @MainActor
    private func assertTestResult(
        _ message: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = app.descendants(matching: .any)["AI Services Test Result"]
        assertExists(result, named: "key test result", timeout: 10, file: file, line: line)
        XCTAssertTrue(
            result.label.contains(message),
            "The key test should read \(message), read \(result.label)",
            file: file,
            line: line
        )
    }

    /// The accessibility tree must not hold any 8-character run of the typed
    /// key. Runs of one repeated character are skipped: they say nothing
    /// about the key and can occur in element addresses.
    @MainActor
    private func assertNoFragment(of key: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let tree = app.debugDescription
        let characters = Array(key)
        for start in 0...(characters.count - 8) {
            let window = characters[start..<(start + 8)]
            guard Set(window).count > 1 else {
                continue
            }
            if tree.contains(String(window)) {
                XCTFail("The accessibility tree holds part of the typed key (offset \(start))", file: file, line: line)
                return
            }
        }
    }

    @MainActor
    private func picker(_ feature: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["AI Services Picker \(feature)"].firstMatch
    }

    @MainActor
    private func assertPickerValue(
        _ picker: XCUIElement,
        beginsWith prefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertExists(picker, named: "provider picker", file: file, line: line)
        let matches = NSPredicate(format: "value BEGINSWITH %@", prefix)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: picker)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "The picker should read \(prefix)…, read \(picker.value as? String ?? "nil")",
            file: file,
            line: line
        )
    }

    @MainActor
    private func openPicker(_ picker: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        scrollUntilHittable(picker, in: app, file: file, line: line)
        // A scroll still decelerating would take the tap instead.
        XCTAssertTrue(waitForStableFrame(of: picker), "The picker should settle before the tap", file: file, line: line)
        picker.tap()
    }

    @MainActor
    private func menuOption(beginningWith prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func openSeededEpisodeDetail(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openSection("Inbox", in: app, file: file, line: line)
        let row = app.buttons.matching(identifier: Self.seededEpisodeRowIdentifier).firstMatch
        assertExists(row, named: "seeded inbox episode", timeout: 10, file: file, line: line)
        row.press(forDuration: 1.2)
        let details = app.buttons["View Episode Details"]
        assertExists(details, named: "View Episode Details context action", file: file, line: line)
        details.tap()
        assertExists(app.buttons["Episode Playback Control"], named: "seeded episode detail", timeout: 10, file: file, line: line)
    }

    /// A dialog sourced from a button may or may not show Cancel on iOS 27;
    /// a tap outside it dismisses it either way.
    @MainActor
    private func dismissDialog(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 1), cancel.isHittable {
            cancel.tap()
            return
        }
        // On iOS 27 the dialog is a popover with no Cancel button: tap
        // outside it, below its frame when there is room, else above.
        let dialog = app.sheets.firstMatch
        let window = app.windows.firstMatch.frame
        let frame = dialog.exists ? dialog.frame : .zero
        let y = frame.maxY + 60 < window.maxY - 120 ? frame.maxY + 60 : max(frame.minY - 30, window.minY + 20)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX, dy: y))
            .tap()
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    @MainActor
    private func waitForStableFrame(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        var frame = element.frame
        while Date.now < deadline {
            usleep(300_000)
            let nextFrame = element.frame
            if nextFrame == frame {
                return true
            }
            frame = nextFrame
        }
        return false
    }

    @MainActor
    private func assertToggle(_ toggle: XCUIElement, isOn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertExists(toggle, named: "sync toggle", file: file, line: line)
        let expected = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        let value = toggle.value as? String
        XCTAssertTrue(
            value.map { expected.contains($0) } ?? false,
            "The sync toggle should be \(isOn ? "on" : "off"), read \(value ?? "nil")",
            file: file,
            line: line
        )
    }

    /// The switch sits at the row's trailing edge; a tap at the row's center
    /// lands on the label.
    @MainActor
    private func tapToggle(_ toggle: XCUIElement, to isOn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertHittable(toggle, named: "sync toggle", file: file, line: line)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let expected = isOn ? ["1", "On", "true"] : ["0", "Off", "false"]
        let changed = NSPredicate { object, _ in
            guard let element = object as? XCUIElement, let value = element.value as? String else {
                return false
            }
            return expected.contains(value)
        }
        let expectation = XCTNSPredicateExpectation(predicate: changed, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, file: file, line: line)
    }
}
