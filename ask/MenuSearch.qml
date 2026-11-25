import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var desktopEntries: DesktopEntries.applications
  property string query: ""
  // Rows are intentionally not capped here.  The result viewport is already
  // bounded and scrollable; capping before bucket balancing hid valid matches
  // and made the promised 20-item fill impossible.
  property int maxRows: 0
  // Matching is cheap, but every change to the row count resizes the card,
  // and the card animates its height. Recomputing per keystroke therefore
  // made fast typing look like the window was flinching. Wait for a pause in
  // typing and resize once, on what was actually typed.
  property int debounceMs: 270
  readonly property bool hasResults: rows.length > 0
  property var rows: []
  property var mathRow: null
  property int mathRequestId: 0
  property var fileRows: []
  property int fileMatchCount: 0
  property bool fileMatchCapped: false
  property bool fileMatchComplete: true
  property var repoRows: []
  property int repoMatchCount: 0
  property bool repoMatchCapped: false
  property bool repoMatchComplete: true
  property int fileRequestId: 0
  property bool fileMode: false
  property bool repoMode: false
  property string fileQueryOverride: ""
  property string focusedBucket: ""
  property bool lastRunKeepsOpen: false

  onFocusedBucketChanged: root.refreshRows()
  onDesktopEntriesChanged: root.refreshRows()

  Connections {
    target: root.desktopEntries
    function onValuesChanged() { root.refreshRows() }
  }

  signal actionRan(string label)
  signal browseRequested(string mode, string query)
  signal pathActionRequested(string path, bool repository, string verb)
  function fallbackAppScore(entry, name, query) {
    var words = name.toLowerCase().split(/[^a-z0-9]+/).filter(function(word) { return word !== "" })
    var genericName = String(entry && (entry.genericName || entry.subtext) || "").toLowerCase()
    var id = String(entry && entry.id || "").toLowerCase()
    var keywords = []
    try { keywords = Array.isArray(entry.keywords) ? entry.keywords : [] } catch (error) { }
    var terms = query.toLowerCase().split(/\s+/).filter(function(term) { return term !== "" })
    var haystacks = [name.toLowerCase(), genericName, id].concat(keywords.map(function(word) {
      return String(word || "").toLowerCase()
    }))
    if (!terms.every(function(term) {
      return haystacks.some(function(haystack) { return haystack.indexOf(term) >= 0 })
    })) return -1
    var lowerName = name.toLowerCase()
    if (lowerName === query.toLowerCase()) return 0
    if (words.indexOf(query.toLowerCase()) >= 0) return 1
    if (lowerName.indexOf(query.toLowerCase()) === 0) return 2
    var nameIndex = lowerName.indexOf(query.toLowerCase())
    if (nameIndex >= 0) return 10 + nameIndex
    if (genericName.indexOf(query.toLowerCase()) >= 0) return 100
    if (id.indexOf(query.toLowerCase()) >= 0) return 200
    return 300
  }

  function matchingApps(text) {
    var value = String(text || "").trim()
    var found = []
    var entries = root.desktopEntries && root.desktopEntries.values
    if (!entries || typeof entries.length !== "number") return found
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var entryName = String(entry && (entry.name || entry.id) || "")
      var score = root.fallbackAppScore(entry, entryName, value)
      if (!entryName || entry.noDisplay || score < 0) continue
      found.push({
        id: "app:" + String(entry.id || entryName), label: entryName,
        path: String(entry.genericName || entry.subtext || "Apps"), icon: "󰀻",
        iconFont: "Symbols Nerd Font Mono", isApp: true,
        appIcon: String(entry.icon || ""), appId: String(entry.id || ""),
        action: "", route: "", score: score, bucketKey: "apps", fallbackApp: true
      })
    }
    return found.sort(function(left, right) {
      return left.score - right.score || left.label.localeCompare(right.label)
    })
  }

  function refreshRows() {
    var text = String(root.query || "").trim()
    if (text === "") { root.rows = []; return }
    var fileOnly = text.indexOf("@") === 0
    var repoOnly = text.indexOf("^") === 0
    if (root.focusedBucket === "apps") {
      var focusedApps = root.matchingApps(text)
      if (focusedApps.length === 0) { root.rows = []; return }
      root.rows = focusedApps.length === 1 ? focusedApps : [{
        id: "apps-results", label: focusedApps.length + " apps", path: "Apps",
        icon: "󰀻", iconFont: "Symbols Nerd Font Mono", isAggregate: true,
        aggregateBucket: "apps", appIcon: "", appId: "", action: "", route: ""
      }].concat(focusedApps)
      return
    }
    var bucketRows = []
    if (fileOnly || repoOnly) {
      var matches = repoOnly ? root.repoRows : root.fileRows
      var focusedRows = []
      for (var f = 0; f < matches.length; f++) {
        var match = matches[f]
        focusedRows.push({
          id: (repoOnly ? "repo:" : "file:") + String(match.path || ""),
          label: match.name || match.path || "",
          path: match.relativePath || match.path || "",
          icon: repoOnly ? "󰊢" : "󰈞",
          iconFont: "Symbols Nerd Font Mono",
          isApp: false,
          isMath: false,
          isPath: true,
          isRepository: repoOnly,
          absolutePath: String(match.path || ""),
          actionHint: repoOnly
            ? "↵ terminal  ·  Ctrl+↵ reveal  ·  Shift+↵ copy path"
            : "↵ view  ·  Ctrl+↵ reveal  ·  Alt+↵ edit  ·  Shift+↵ copy",
          appIcon: "", appId: "", action: "", route: "", score: f,
          bucketKey: repoOnly ? "repos" : "files"
        })
      }
      var focusedCount = repoOnly ? root.repoMatchCount : root.fileMatchCount
      var focusedCapped = repoOnly ? root.repoMatchCapped : root.fileMatchCapped
      var focusedComplete = repoOnly ? root.repoMatchComplete : root.fileMatchComplete
      var focusedLabel = root.matchSummaryLabel(focusedCount, focusedCapped,
        repoOnly ? "repositories" : "files")
      var focusedAggregate = {
        id: repoOnly ? "repo-results" : "file-results",
        label: focusedLabel,
        path: repoOnly ? "Repositories" : "Files",
        icon: repoOnly ? "󰊢" : "󰈞", iconFont: "Symbols Nerd Font Mono",
        isAggregate: true, aggregateBucket: repoOnly ? "repos" : "files",
        appIcon: "", appId: "", action: "", route: ""
      }
      root.rows = root.isSingleMatch(focusedRows, focusedCount || focusedRows.length,
        focusedCapped, focusedComplete) ? focusedRows : [focusedAggregate].concat(focusedRows)
      return
    }
    var scored = []
    var goRows = []
    // Math remains an individual result after the bucket headers.
    if (root.mathRow && root.mathRow.query === root.query) goRows.push({
      id: "math:" + root.mathRequestId,
      label: root.mathRow.expression + " = " + root.mathRow.answer,
      path: "", icon: "", iconFont: "", isApp: false, isMath: true,
      equation: root.mathRow.expression + " =", answer: root.mathRow.answer,
      appIcon: "", appId: "", action: "", route: "", score: -2,
      bucketKey: "go"
    })
    var appMatches = root.matchingApps(text)
    if (root.fileRows.length > 0) bucketRows.unshift({
      key: "files", label: "files", icon: "󰈞", rows: root.fileRows.map(function(match, index) {
        return {
          id: "file:" + String(match.path || index), label: match.name || match.path || "",
          path: match.relativePath || match.path || "", icon: "󰈞", iconFont: "Symbols Nerd Font Mono",
          isPath: true, isRepository: false, absolutePath: String(match.path || ""),
          actionHint: "↵ view  ·  Ctrl+↵ reveal  ·  Alt+↵ edit  ·  Shift+↵ copy",
          appIcon: "", appId: "", action: "", route: "", score: index, bucketKey: "files"
        }
      })
    })
    if (root.repoRows.length > 0) bucketRows.splice(root.fileRows.length > 0 ? 1 : 0, 0, {
      key: "repos", label: "repositories", icon: "󰊢", rows: root.repoRows.map(function(match, index) {
        return {
          id: "repo:" + String(match.path || index), label: match.name || match.path || "",
          path: match.relativePath || match.path || "", icon: "󰊢", iconFont: "Symbols Nerd Font Mono",
          isPath: true, isRepository: true, absolutePath: String(match.path || ""),
          actionHint: "↵ terminal  ·  Ctrl+↵ reveal  ·  Shift+↵ copy path",
          appIcon: "", appId: "", action: "", route: "", score: index, bucketKey: "repos"
        }
      })
    })
    if (appMatches.length > 0)
      bucketRows.unshift({ key: "apps", label: "apps", icon: "󰀻", rows: appMatches })

    var appPrefix = []
    var appPreviewCount = 0
    var shownCount = {}
    var promotedCount = 0
    for (var b = 0; b < bucketRows.length; b++) {
      var bucket = bucketRows[b]
      var count = bucket.key === "files" ? root.fileMatchCount || bucket.rows.length
        : (bucket.key === "repos" ? root.repoMatchCount || bucket.rows.length : bucket.rows.length)
      var capped = bucket.key === "files" ? root.fileMatchCapped
        : (bucket.key === "repos" && root.repoMatchCapped)
      var complete = bucket.key === "files" ? root.fileMatchComplete
        : (bucket.key !== "repos" || root.repoMatchComplete)
      if (root.isSingleMatch(bucket.rows, count, capped, complete)) {
        if (bucket.key === "apps") appPrefix.push(bucket.rows[0])
        else scored.push(bucket.rows[0])
        shownCount[bucket.key] = 1
        promotedCount++
        continue
      }
      var summary = {
        id: bucket.key + "-results", label: root.matchSummaryLabel(count, capped,
          bucket.label),
        path: bucket.label.charAt(0).toUpperCase() + bucket.label.slice(1),
        icon: bucket.icon, iconFont: "Symbols Nerd Font Mono", isAggregate: true,
        aggregateBucket: bucket.key, appIcon: "", appId: "", action: "", route: ""
      }
      if (bucket.key !== "apps") {
        scored.push(summary)
        continue
      }
      appPrefix.push(summary)
      appPreviewCount = Math.min(2, bucket.rows.length)
      for (var appIndex = 0; appIndex < appPreviewCount; appIndex++)
        appPrefix.push(bucket.rows[appIndex])
      shownCount.apps = appPreviewCount
    }
    goRows.sort(function(a, b) { return a.score - b.score || a.label.localeCompare(b.label) })
    scored = scored.concat(goRows)
    var shown = []
    for (var seed = 0; seed < bucketRows.length; seed++) {
      var seedBucket = bucketRows[seed]
      if (shownCount[seedBucket.key]) continue
      shownCount[seedBucket.key] = 0
      if (seedBucket.rows.length > 0) {
        shown.push(seedBucket.rows[0]); shownCount[seedBucket.key] = 1
      }
      if (seedBucket.rows.length > 1) {
        shown.push(seedBucket.rows[1]); shownCount[seedBucket.key] = 2
      }
    }
    var wantedIndividuals = 20
    var individualCount = promotedCount + appPreviewCount + goRows.length + shown.length
    var cursor = 0
    while (individualCount < wantedIndividuals) {
      var candidates = bucketRows.filter(function(bucket) {
        return (shownCount[bucket.key] || 0) < bucket.rows.length
      })
      if (candidates.length === 0) break
      var minimum = Math.min.apply(null, candidates.map(function(bucket) { return shownCount[bucket.key] || 0 }))
      var chosen = null
      for (var step = 0; step < bucketRows.length; step++) {
        var candidate = bucketRows[(cursor + step) % bucketRows.length]
        if (candidate && (shownCount[candidate.key] || 0) === minimum
            && (shownCount[candidate.key] || 0) < candidate.rows.length) {
          chosen = candidate; cursor = (cursor + step + 1) % bucketRows.length; break
        }
      }
      if (!chosen) break
      shown.push(chosen.rows[shownCount[chosen.key] || 0])
      shownCount[chosen.key] = (shownCount[chosen.key] || 0) + 1
      individualCount++
    }
    root.rows = appPrefix.concat(scored).concat(shown)
  }

  function isSingleMatch(matches, count, capped, complete) {
    // A known single path is safe to activate while other partitions are
    // still running.  It must not be hidden behind a misleading aggregate;
    // Show it directly when it is the only known row and the count is uncapped.
    return matches.length === 1 && count === 1 && !capped
  }

  function matchSummaryLabel(count, capped, label) {
    var suffix = capped ? "+" : ""
    return String(Number(count) || 0) + suffix + " " + label
  }

  function run(index, modifiers) {
    if (index < 0 || index >= root.rows.length) return false
    var row = root.rows[index]
    root.lastRunKeepsOpen = false
    if (row.isMath) {
      Quickshell.execDetached(["wl-copy", String(row.answer)])
    } else if (row.isAggregate) {
      root.lastRunKeepsOpen = true
      if (row.aggregateBucket === "files" || row.aggregateBucket === "repos"
          || row.aggregateBucket === "apps")
        root.browseRequested(row.aggregateBucket, root.query)
      return true
    } else if (row.isPath) {
      var flags = Number(modifiers || 0)
      var verb = (flags & Qt.ControlModifier) !== 0 ? "reveal"
        : ((flags & Qt.ShiftModifier) !== 0 ? "copy"
        : ((flags & Qt.AltModifier) !== 0 ? "edit" : "open"))
      root.pathActionRequested(row.absolutePath, Boolean(row.isRepository), verb)
    } else if (row.isApp) {
      var desktopId = String(row.appId || "").replace(/\.desktop$/i, "")
      if (!desktopId) return false
      Quickshell.execDetached(["gtk-launch", "--", desktopId])
    }
    root.actionRan(row.label)
    return true
  }

  // Clearing the box collapses the list at once -- there is nothing to settle
  // on, and holding an empty result open for the debounce would just look
  // broken. Everything else waits for the pause.
  onQueryChanged: {
    searchDebounce.stop()
    // Invalidate every in-flight generation immediately. Nothing new is sent
    // until typing has paused, so late results cannot jitter the current rows.
    root.mathRequestId++
    root.fileRequestId++
    root.mathRow = null
    root.fileRows = []
    root.fileMatchCount = 0
    root.fileMatchCapped = false
    root.fileMatchComplete = true
    root.repoRows = []
    root.repoMatchCount = 0
    root.repoMatchCapped = false
    root.repoMatchComplete = true
    root.rows = []
    if (String(root.query || "").trim() === "") {
      return
    }
    searchDebounce.restart()
  }

  function runSettledSearch() {
    if (String(root.query || "").trim() === "") return
    root.mathRequestId++
    if (mathProc.running) mathProc.write(JSON.stringify({
      id: root.mathRequestId,
      query: root.query
    }) + "\n")
    root.requestFiles()
    root.refreshRows()
  }

  onFileQueryOverrideChanged: if (root.fileMode || root.repoMode) root.requestFiles()
  onFileModeChanged: if (root.fileMode) root.requestFiles()
  onRepoModeChanged: if (root.repoMode) root.requestFiles()

  function requestFiles() {
    var focused = root.fileMode || root.repoMode
      || /^[@^]/.test(String(root.query || "").trim())
    var wanted = (root.fileMode || root.repoMode) ? root.fileQueryOverride : root.query
    wanted = String(wanted || "").replace(/^[@^]/, "").trim()
    // Rows belong to one query generation. Clear them before advancing the id
    // so the UI cannot briefly relabel the previous query's 100 results as
    // matches for the text that was just typed.
    root.fileRows = []
    root.fileMatchCount = 0
    root.fileMatchCapped = false
    root.fileMatchComplete = true
    root.repoRows = []
    root.repoMatchCount = 0
    root.repoMatchCapped = false
    root.repoMatchComplete = true
    root.fileRequestId++
    if (fileProc.running) fileProc.write(JSON.stringify({
      id: root.fileRequestId,
      query: wanted,
      focused: focused
    }) + "\n")
  }

  function acceptFiles(line) {
    try {
      var message = JSON.parse(String(line || ""))
      if (Number(message.id) !== root.fileRequestId) return
      if (message.repoOnly !== true) {
        var nextFileRows = message.rows || []
        root.fileMatchCount = Number(message.totalMatched) || nextFileRows.length
        root.fileMatchCapped = message.capped === true
        root.fileMatchComplete = message.complete !== false
        root.fileRows = nextFileRows
      }
      if (Array.isArray(message.repos)) {
        var nextRepoRows = message.repos
        root.repoMatchCount = Number(message.repoTotalMatched) || nextRepoRows.length
        root.repoMatchCapped = message.repoCapped === true
        root.repoMatchComplete = message.repoComplete !== false
        root.repoRows = nextRepoRows
      }
      if (!root.fileMode && !root.repoMode) root.refreshRows()
    } catch (error) { }
  }

  function acceptMath(line) {
    try {
      var message = JSON.parse(String(line || ""))
      if (Number(message.id) !== root.mathRequestId) return
      root.mathRow = message.result ? {
        query: String(message.query || ""),
        expression: String(message.result.expression || ""),
        answer: String(message.result.answer || "")
      } : null
      root.refreshRows()
    } catch (error) { }
  }

  Process {
    id: mathProc
    command: [
      "node",
      Paths.bridge("math.js")
    ]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.acceptMath(line) } }
  }

  Process {
    id: fileProc
    command: [
      "node",
      Paths.bridge("files.js")
    ]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.acceptFiles(line) } }
  }

  Timer {
    id: searchDebounce
    interval: root.debounceMs
    repeat: false
    onTriggered: root.runSettledSearch()
  }

}
