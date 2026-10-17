package github.realtvop.aonsoku.plugins.debug

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.ServiceConnection
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.content.ClipboardManager
import android.text.Editable
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.*
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.appbar.AppBarLayout
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.color.MaterialColors
import com.google.android.material.tabs.TabLayout
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import github.realtvop.aonsoku.plugins.audio.PlaybackService
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.plugins.bridge.AndroidCredentialStore
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class DebugActivity : AppCompatActivity() {
    private var playbackService: PlaybackService? = null
    private var isBound = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var refreshTimer: Handler? = null
    private var currentTab = 0

    private lateinit var tabLayout: TabLayout
    private lateinit var contentFrame: FrameLayout
    private lateinit var playbackContent: ScrollView
    private lateinit var playbackContainer: LinearLayout
    private lateinit var infoContent: ScrollView
    private lateinit var infoContainer: LinearLayout
    private lateinit var logsTabContent: LinearLayout
    private lateinit var logsRecyclerView: RecyclerView
    private lateinit var logAdapter: LogAdapter
    private lateinit var logsActionBar: LinearLayout
    
    private lateinit var searchEditText: TextInputEditText
    private lateinit var levelChipGroup: ChipGroup
    private lateinit var sourceChipGroup: ChipGroup

    private var searchText = ""
    private var activeLevels = mutableSetOf(NativeLogger.Entry.Level.DEBUG, NativeLogger.Entry.Level.INFO, NativeLogger.Entry.Level.WARN, NativeLogger.Entry.Level.ERROR)
    private var activeSources = mutableSetOf<String>()
    private var allSources = listOf<String>()
    private var isSelectingLogs = false
    private var selectedLogIndices = mutableSetOf<Int>()

    private val credentialStore by lazy { AndroidCredentialStore(this) }

    private val timeFormatter = SimpleDateFormat("HH:mm:ss", Locale.US)
    private val copyTimeFormatter = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? PlaybackService.LocalBinder
            playbackService = binder?.getService()
            isBound = true
            NativeLogger.debug("DebugActivity bound to PlaybackService", "debug-activity")
            refreshCurrentTab()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            playbackService = null
            isBound = false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val isTabletResId = resources.getIdentifier("is_tablet", "bool", packageName)
        if (isTabletResId != 0 && !resources.getBoolean(isTabletResId)) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        setTheme(com.google.android.material.R.style.Theme_Material3_DayNight_NoActionBar)
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(createMainLayout())
        bindPlaybackService()
        startAutoRefresh()
        NativeLogger.info("DebugActivity opened", "debug-activity")
    }

    override fun onDestroy() {
        stopAutoRefresh()
        if (isBound) {
            unbindService(connection)
            isBound = false
        }
        super.onDestroy()
    }

    private fun createMainLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            setBackgroundColor(getThemeColor(com.google.android.material.R.attr.colorSurface))
        }

        val appBar = AppBarLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            elevation = 0f
            setBackgroundColor(Color.TRANSPARENT)
        }

        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            appBar.setPadding(0, systemBars.top, 0, 0)
            
            // Apply bottom inset to content that touches the bottom
            playbackContent.setPadding(0, 0, 0, systemBars.bottom)
            infoContent.setPadding(0, 0, 0, systemBars.bottom)
            
            // Apply bottom inset to logs action bar
            if (::logsActionBar.isInitialized) {
                logsActionBar.setPadding(dp(16), dp(8), dp(16), dp(8) + systemBars.bottom)
            }
            
            insets
        }

        val toolbar = MaterialToolbar(this).apply {
            title = "Debug Monitor"
            setTitleTextAppearance(this@DebugActivity, com.google.android.material.R.style.TextAppearance_Material3_TitleLarge)
            
            // 使用标准的 AppCompat Material 返回箭头图标
            setNavigationIcon(androidx.appcompat.R.drawable.abc_ic_ab_back_material)
            // 确保图标颜色符合 Material You 的 colorOnSurface 规范
            setNavigationIconTint(getThemeColor(com.google.android.material.R.attr.colorOnSurface))

            setNavigationOnClickListener { finish() }
        }
        appBar.addView(toolbar)

        tabLayout = TabLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setBackgroundColor(Color.TRANSPARENT)
            setSelectedTabIndicatorColor(getThemeColor(com.google.android.material.R.attr.colorPrimary))
            tabTextColors = ColorStateList.valueOf(getThemeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
            tabMode = TabLayout.MODE_FIXED
            
            addTab(newTab().setText("Playback"))
            addTab(newTab().setText("Info"))
            addTab(newTab().setText("Logs"))
            
            addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
                override fun onTabSelected(tab: TabLayout.Tab?) {
                    switchTab(tab?.position ?: 0)
                }
                override fun onTabUnselected(tab: TabLayout.Tab?) {}
                override fun onTabReselected(tab: TabLayout.Tab?) {}
            })
        }
        appBar.addView(tabLayout)
        root.addView(appBar)

        contentFrame = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
        }
        root.addView(contentFrame)

        setupPlaybackTab()
        setupInfoTab()
        setupLogsTab()
        
        showTabContent(0)

        return root
    }

    private fun dp(value: Int): Int {
        val scale = resources.displayMetrics.density
        return (value * scale + 0.5f).toInt()
    }

    private fun getThemeColor(attr: Int): Int {
        return MaterialColors.getColor(this, attr, Color.MAGENTA)
    }

    private fun switchTab(index: Int) {
        currentTab = index
        isSelectingLogs = false
        selectedLogIndices.clear()
        showTabContent(index)
    }

    private fun showTabContent(index: Int) {
        contentFrame.removeAllViews()
        when (index) {
            0 -> {
                contentFrame.addView(playbackContent)
                refreshPlaybackTab()
            }
            1 -> {
                contentFrame.addView(infoContent)
                refreshInfoTab()
            }
            2 -> {
                contentFrame.addView(logsTabContent)
                refreshLogsTab()
            }
        }
    }

    // MARK: - Playback Tab

    private fun setupPlaybackTab() {
        playbackContent = ScrollView(this).apply {
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            isFillViewport = true
            clipToPadding = false
        }
        playbackContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(16))
        }
        playbackContent.addView(playbackContainer)
    }

    private fun refreshPlaybackTab() {
        playbackContainer.removeAllViews()

        val service = playbackService
        val player = service?.getPlayer()

        // Now Playing Card
        val (nowPlayingCard, nowPlayingContent) = createCard("NOW PLAYING")
        
        val title = player?.currentMediaItem?.mediaMetadata?.title?.toString() ?: "(idle)"
        val artist = player?.currentMediaItem?.mediaMetadata?.artist?.toString() ?: ""
        
        TextView(this).apply {
            text = title
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(getThemeColor(com.google.android.material.R.attr.colorOnSurface))
        }.let { nowPlayingContent.addView(it) }
        
        TextView(this).apply {
            text = artist
            textSize = 14f
            setTextColor(getThemeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
            setPadding(0, 0, 0, dp(12))
        }.let { nowPlayingContent.addView(it) }

        val curPos = if (player != null) player.currentPosition / 1000.0 else 0.0
        val duration = if (player != null && player.duration != C.TIME_UNSET) player.duration / 1000.0 else 0.0
        val buffered = if (player != null) player.bufferedPosition / 1000.0 else 0.0
        
        val progressContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progress = if (duration > 0) (curPos / duration * 1000).toInt() else 0
            secondaryProgress = if (duration > 0) (buffered / duration * 1000).toInt() else 0
            progressTintList = ColorStateList.valueOf(getThemeColor(com.google.android.material.R.attr.colorPrimary))
            progressBackgroundTintList = ColorStateList.valueOf(getThemeColor(com.google.android.material.R.attr.colorSurfaceVariant))
        }
        progressContainer.addView(progressBar)
        
        val timeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            layoutParams = lp
        }
        timeRow.addView(TextView(this).apply { 
            text = formatTime(curPos)
            textSize = 12f
            alpha = 0.7f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        timeRow.addView(TextView(this).apply { 
            text = formatTime(duration)
            textSize = 12f
            alpha = 0.7f
        })
        progressContainer.addView(timeRow)
        nowPlayingContent.addView(progressContainer)
        
        playbackContainer.addView(nowPlayingCard)

        // Controls
        playbackContainer.addView(controlsRow())

        // Mode Info
        val (modeCard, modeContent) = createCard("PLAYBACK MODE")
        val kind = if (service?.isQueueEngineActive == true) "Queue Engine" else "Single Track"
        val repeatMode = service?.queueEngine?.loopState?.value ?: "off"
        val shuffle = if (service?.queueEngine?.isShuffleActive == true) "On" else "Off"
        
        modeContent.addView(kvRow("Type", kind))
        modeContent.addView(kvRow("Repeat", repeatMode.replaceFirstChar { it.uppercase() }))
        modeContent.addView(kvRow("Shuffle", shuffle))
        playbackContainer.addView(modeCard)

        // Queue
        val contextSongs = service?.queueEngine?.contextSongs ?: emptyList()
        val currentIndex = service?.queueEngine?.currentIndex ?: 0
        val isInUserQueue = service?.queueEngine?.isInUserQueue ?: false

        val (queueCard, queueContent) = createCard("QUEUE (${contextSongs.size})")
        if (contextSongs.isEmpty()) {
            queueContent.addView(TextView(this).apply { text = "Queue is empty"; alpha = 0.5f; textSize = 12f })
        } else {
            contextSongs.forEachIndexed { i, song ->
                val isCurrent = !isInUserQueue && i == currentIndex
                queueContent.addView(queueRow(song, isCurrent))
            }
        }
        playbackContainer.addView(queueCard)
        
        val userQueue = service?.queueEngine?.userQueue ?: emptyList()
        if (userQueue.isNotEmpty()) {
            val (uQueueCard, uQueueContent) = createCard("USER QUEUE (${userQueue.size})")
            userQueue.forEach { song ->
                uQueueContent.addView(queueRow(song, false))
            }
            playbackContainer.addView(uQueueCard)
        }
    }

    private fun controlsRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, dp(8))
        }

        val btnParams = LinearLayout.LayoutParams(dp(56), dp(56)).apply { setMargins(dp(8), 0, dp(8), 0) }
        
        val prevBtn = MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = "⏮"
            layoutParams = btnParams
            cornerRadius = dp(28)
            setPadding(0, 0, 0, 0)
            insetTop = 0
            insetBottom = 0
            setOnClickListener {
                val service = playbackService
                if (service != null && service.isQueueEngineActive) {
                    val player = service.getPlayer()
                    val currentTime = if (player != null) player.currentPosition / 1000.0 else 0.0
                    service.queueEngine.skipToPrevious(currentTime)
                }
            }
        }
        row.addView(prevBtn)

        val player = playbackService?.getPlayer()
        val isPlaying = player?.isPlaying == true
        val playPauseBtn = MaterialButton(this).apply {
            text = if (isPlaying) "⏸" else "▶"
            layoutParams = btnParams
            cornerRadius = dp(28)
            setPadding(0, 0, 0, 0)
            insetTop = 0
            insetBottom = 0
            setOnClickListener {
                val p = playbackService?.getPlayer()
                if (p?.isPlaying == true) {
                    p.pause()
                } else {
                    p?.play()
                }
            }
        }
        row.addView(playPauseBtn)

        val nextBtn = MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            text = "⏭"
            layoutParams = btnParams
            cornerRadius = dp(28)
            setPadding(0, 0, 0, 0)
            insetTop = 0
            insetBottom = 0
            setOnClickListener {
                val service = playbackService
                if (service != null && service.isQueueEngineActive) {
                    service.queueEngine.skipToNext()
                }
            }
        }
        row.addView(nextBtn)

        return row
    }

    private fun queueRow(song: QueueSong, isCurrent: Boolean): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(6), 0, dp(6))
            gravity = Gravity.CENTER_VERTICAL
        }
        
        if (isCurrent) {
            val indicator = View(this).apply {
                layoutParams = LinearLayout.LayoutParams(dp(4), dp(16)).apply { marginEnd = dp(8) }
                setBackgroundColor(getThemeColor(com.google.android.material.R.attr.colorPrimary))
            }
            row.addView(indicator)
        }

        TextView(this).apply {
            text = song.title
            textSize = 13f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(if (isCurrent) getThemeColor(com.google.android.material.R.attr.colorPrimary) else getThemeColor(com.google.android.material.R.attr.colorOnSurface))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }.let { row.addView(it) }

        TextView(this).apply {
            text = formatTime(song.duration)
            textSize = 11f
            alpha = 0.6f
            setPadding(dp(8), 0, 0, 0)
        }.let { row.addView(it) }

        return row
    }

    // MARK: - Info Tab

    private fun setupInfoTab() {
        infoContent = ScrollView(this).apply {
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            isFillViewport = true
            clipToPadding = false
        }
        infoContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(16))
        }
        infoContent.addView(infoContainer)
    }

    private fun refreshInfoTab() {
        infoContainer.removeAllViews()

        val service = playbackService
        val player = service?.getPlayer()

        // Player Status
        val (statusCard, statusContent) = createCard("PLAYER STATUS")
        val playbackState = player?.playbackState ?: Player.STATE_IDLE
        val statusText = when (playbackState) {
            Player.STATE_BUFFERING -> "Buffering"
            Player.STATE_READY -> if (player?.isPlaying == true) "Playing" else "Paused"
            Player.STATE_ENDED -> "Ended"
            else -> "Idle"
        }
        val statusColor = when (playbackState) {
            Player.STATE_BUFFERING -> 0xFFFB8C00.toInt()
            Player.STATE_READY -> if (player?.isPlaying == true) 0xFF43A047.toInt() else 0xFF1976D2.toInt()
            else -> getThemeColor(com.google.android.material.R.attr.colorOnSurfaceVariant)
        }
        statusContent.addView(kvRow("State", statusText, valueColor = statusColor))
        statusContent.addView(kvRow("Volume", String.format(Locale.US, "%.0f%%", (player?.volume ?: 0f) * 100)))
        infoContainer.addView(statusCard)

        // Connection
        val (connCard, connContent) = createCard("CONNECTION")
        val creds = credentialStore.retrieve()
        if (creds != null) {
            connContent.addView(kvRow("Server", creds.serverUrl))
            connContent.addView(kvRow("User", creds.username))
            connContent.addView(kvRow("Auth", "${creds.authType} (${creds.protocolVersion})"))
            val typeInfo = creds.serverType + if (!creds.fallbackUrl.isNullOrBlank()) " (+fallback)" else ""
            connContent.addView(kvRow("Type", typeInfo))
        } else {
            connContent.addView(TextView(this).apply { text = "No credentials found"; alpha = 0.5f; textSize = 12f })
        }
        infoContainer.addView(connCard)

        // System
        val (sysCard, sysContent) = createCard("SYSTEM")
        val am = getSystemService(AUDIO_SERVICE) as? AudioManager
        val vol = am?.let {
            val max = it.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val cur = it.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (max > 0) "$cur / $max" else "?"
        } ?: "?"
        sysContent.addView(kvRow("System Vol", vol))
        sysContent.addView(kvRow("Memory", String.format(Locale.US, "%.1f MB", memoryUsageMB())))
        sysContent.addView(kvRow("Android", "API ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})"))
        sysContent.addView(kvRow("Device", "${Build.MANUFACTURER} ${Build.MODEL}"))
        infoContainer.addView(sysCard)
    }

    private fun memoryUsageMB(): Double {
        val runtime = Runtime.getRuntime()
        return (runtime.totalMemory() - runtime.freeMemory()) / (1024.0 * 1024.0)
    }

    // MARK: - Logs Tab

    private fun setupLogsTab() {
        logsTabContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }

        // Search Bar
        val searchInputLayout = TextInputLayout(this, null, com.google.android.material.R.attr.textInputOutlinedStyle).apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                setMargins(dp(16), dp(8), dp(16), dp(8))
            }
            hint = "Search logs..."
            placeholderText = "Type message or source"
            setStartIconDrawable(android.R.drawable.ic_menu_search)
            setBoxCornerRadii(dp(12).toFloat(), dp(12).toFloat(), dp(12).toFloat(), dp(12).toFloat())
        }
        searchEditText = TextInputEditText(searchInputLayout.context).apply {
            textSize = 14f
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    searchText = s?.toString() ?: ""
                    applyLogFilter()
                }
            })
        }
        searchInputLayout.addView(searchEditText)
        logsTabContent.addView(searchInputLayout)

        // Filters
        val filterScroll = HorizontalScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            isHorizontalScrollBarEnabled = false
            setPadding(dp(16), 0, dp(16), dp(8))
            clipToPadding = false
        }
        val chipContainer = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        
        levelChipGroup = ChipGroup(this).apply {
            isSingleSelection = false
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        chipContainer.addView(levelChipGroup)
        
        val divider = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(1), dp(24)).apply { setMargins(dp(12), 0, dp(12), 0) }
            setBackgroundColor(getThemeColor(com.google.android.material.R.attr.colorOutlineVariant))
            alpha = 0.5f
        }
        chipContainer.addView(divider)
        
        sourceChipGroup = ChipGroup(this).apply {
            isSingleSelection = false
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
        chipContainer.addView(sourceChipGroup)
        
        filterScroll.addView(chipContainer)
        logsTabContent.addView(filterScroll)

        // Recycler
        logsRecyclerView = RecyclerView(this).apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
            layoutManager = LinearLayoutManager(this@DebugActivity)
        }
        logAdapter = LogAdapter()
        logsRecyclerView.adapter = logAdapter
        logsTabContent.addView(logsRecyclerView)

        // Bottom Action Bar
        logsActionBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(16), dp(8), dp(16), dp(8))
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(getThemeColor(com.google.android.material.R.attr.colorSurface))
            elevation = dp(8).toFloat()
        }
        
        val selectBtn = MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            setText("Select")
            textSize = 12f
            setOnClickListener {
                isSelectingLogs = !isSelectingLogs
                setText(if (isSelectingLogs) "Cancel" else "Select")
                selectedLogIndices.clear()
                logAdapter.notifyDataSetChanged()
            }
        }
        logsActionBar.addView(selectBtn)
        
        val space = View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 1, 1f) }
        logsActionBar.addView(space)
        
        val copyBtn = MaterialButton(this).apply {
            setText("Copy")
            textSize = 12f
            isEnabled = false
            setOnClickListener {
                if (isSelectingLogs && selectedLogIndices.isNotEmpty()) {
                    val entries = getFilteredEntries()
                    val textToCopy = selectedLogIndices.sorted().mapNotNull { idx ->
                        entries.getOrNull(idx)?.let { entry ->
                            val time = copyTimeFormatter.format(Date(entry.timestamp))
                            val src = if (entry.source.isEmpty()) "" else "[${entry.source}] "
                            "$time ${entry.level.name} $src${entry.message}"
                        }
                    }.joinToString("\n")
                    copyToClipboard(textToCopy)
                    isSelectingLogs = false
                    selectBtn.setText("Select")
                    selectedLogIndices.clear()
                    logAdapter.notifyDataSetChanged()
                    Toast.makeText(this@DebugActivity, "Copied selected logs", Toast.LENGTH_SHORT).show()
                }
            }
        }
        logsActionBar.addView(copyBtn)
        
        val clearBtn = MaterialButton(this, null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
            setText("Clear")
            textSize = 12f
            setPadding(dp(8), 0, dp(8), 0)
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(8) }
            setOnClickListener {
                NativeLogger.clear()
                refreshLogsTab()
            }
        }
        logsActionBar.addView(clearBtn)
        
        logsTabContent.addView(logsActionBar)
        
        // Update copy button state
        mainHandler.post(object : Runnable {
            override fun run() {
                copyBtn.isEnabled = isSelectingLogs && selectedLogIndices.isNotEmpty()
                mainHandler.postDelayed(this, 200)
            }
        })
    }

    private fun refreshLogsTab() {
        updateSources()
        rebuildFilters()
        applyLogFilter()
    }

    private fun updateSources() {
        val entries = NativeLogger.getEntries()
        val sources = entries.mapNotNull { it.source.ifEmpty { null } }.toSet()
        val sorted = sources.sorted()
        if (sorted != allSources) {
            allSources = sorted
            if (activeSources.isEmpty()) {
                activeSources = sources.toMutableSet()
            }
        }
    }

    private fun getFilteredEntries(): List<NativeLogger.Entry> {
        val allEntries = NativeLogger.getEntries().reversed()
        return allEntries.filter { entry ->
            if (!activeLevels.contains(entry.level)) return@filter false
            if (activeSources.isNotEmpty() && entry.source.isNotEmpty()) {
                if (!activeSources.contains(entry.source)) return@filter false
            }
            if (searchText.isNotEmpty()) {
                val haystack = "${entry.source} ${entry.message}".lowercase()
                if (!haystack.contains(searchText.lowercase())) return@filter false
            }
            true
        }
    }

    private fun applyLogFilter() {
        logAdapter.setEntries(getFilteredEntries())
    }

    private fun rebuildFilters() {
        if (levelChipGroup.childCount == 0) {
            for (level in NativeLogger.Entry.Level.entries) {
                val chip = Chip(this).apply {
                    text = level.name
                    isCheckable = true
                    isChecked = activeLevels.contains(level)
                    textSize = 11f
                    setOnCheckedChangeListener { _, isChecked ->
                        if (isChecked) activeLevels.add(level) else activeLevels.remove(level)
                        applyLogFilter()
                    }
                }
                levelChipGroup.addView(chip)
            }
        }
        
        // Sources chips - update if list changed
        val currentChips = (0 until sourceChipGroup.childCount).map { (sourceChipGroup.getChildAt(it) as Chip).text.toString() }
        if (currentChips != allSources) {
            sourceChipGroup.removeAllViews()
            for (source in allSources) {
                val chip = Chip(this).apply {
                    text = source
                    isCheckable = true
                    isChecked = activeSources.contains(source)
                    textSize = 11f
                    setOnCheckedChangeListener { _, isChecked ->
                        if (isChecked) activeSources.add(source) else activeSources.remove(source)
                        applyLogFilter()
                    }
                }
                sourceChipGroup.addView(chip)
            }
        }
    }

    private fun copyToClipboard(text: String) {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("debug_log", text))
    }

    // MARK: - Common UI Helpers

    private fun createCard(title: String): Pair<MaterialCardView, LinearLayout> {
        val card = MaterialCardView(this).apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                setMargins(0, dp(8), 0, dp(8))
            }
            radius = dp(16).toFloat()
            cardElevation = 0f
            setCardBackgroundColor(getThemeColor(com.google.android.material.R.attr.colorSurfaceVariant))
            strokeWidth = 0
        }
        
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
        }
        
        val titleView = TextView(this).apply {
            text = title
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(getThemeColor(com.google.android.material.R.attr.colorPrimary))
            setPadding(0, 0, 0, dp(8))
            alpha = 0.8f
        }
        container.addView(titleView)
        
        card.addView(container)
        return Pair(card, container)
    }

    private fun kvRow(key: String, value: String, valueColor: Int? = null): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(4), 0, dp(4))
        }

        TextView(this).apply {
            text = key
            textSize = 13f
            typeface = Typeface.MONOSPACE
            setTextColor(getThemeColor(com.google.android.material.R.attr.colorOnSurfaceVariant))
            layoutParams = LinearLayout.LayoutParams(dp(100), ViewGroup.LayoutParams.WRAP_CONTENT)
        }.let { row.addView(it) }

        TextView(this).apply {
            text = value
            textSize = 13f
            typeface = Typeface.MONOSPACE
            setTextColor(valueColor ?: getThemeColor(com.google.android.material.R.attr.colorOnSurface))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }.let { row.addView(it) }

        return row
    }

    private fun formatTime(seconds: Double): String {
        if (seconds.isNaN() || seconds.isInfinite() || seconds < 0) return "0:00"
        val mins = seconds.toInt() / 60
        val secs = seconds.toInt() % 60
        return String.format(Locale.US, "%d:%02d", mins, secs)
    }

    // MARK: - Adapter

    inner class LogAdapter : RecyclerView.Adapter<LogAdapter.ViewHolder>() {
        private var entries: List<NativeLogger.Entry> = emptyList()

        fun setEntries(newEntries: List<NativeLogger.Entry>) {
            entries = newEntries
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
            val container = LinearLayout(parent.context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                setPadding(dp(16), dp(8), dp(16), dp(8))
                isClickable = true
                isFocusable = true
                val outValue = TypedValue()
                context.theme.resolveAttribute(android.R.attr.selectableItemBackground, outValue, true)
                setBackgroundResource(outValue.resourceId)
            }
            
            val header = LinearLayout(parent.context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            
            val levelView = TextView(parent.context).apply {
                textSize = 9f
                typeface = Typeface.DEFAULT_BOLD
                setPadding(dp(4), dp(1), dp(4), dp(1))
            }
            header.addView(levelView)
            
            val timeView = TextView(parent.context).apply {
                textSize = 10f
                setPadding(dp(8), 0, 0, 0)
                alpha = 0.6f
            }
            header.addView(timeView)
            
            val sourceView = TextView(parent.context).apply {
                textSize = 10f
                setPadding(dp(8), 0, 0, 0)
                typeface = Typeface.MONOSPACE
                alpha = 0.6f
            }
            header.addView(sourceView)
            
            container.addView(header)
            
            val messageView = TextView(parent.context).apply {
                textSize = 12f
                typeface = Typeface.MONOSPACE
                setPadding(0, dp(2), 0, 0)
                setTextColor(getThemeColor(com.google.android.material.R.attr.colorOnSurface))
            }
            container.addView(messageView)
            
            return ViewHolder(container, levelView, timeView, sourceView, messageView)
        }

        override fun onBindViewHolder(holder: ViewHolder, position: Int) {
            val entry = entries[position]
            holder.messageView.text = entry.message
            holder.timeView.text = timeFormatter.format(Date(entry.timestamp))
            holder.sourceView.text = if (entry.source.isEmpty()) "" else "@${entry.source}"
            
            val color = when (entry.level) {
                NativeLogger.Entry.Level.ERROR -> 0xFFD32F2F.toInt()
                NativeLogger.Entry.Level.WARN -> 0xFFF57C00.toInt()
                NativeLogger.Entry.Level.INFO -> 0xFF1976D2.toInt()
                NativeLogger.Entry.Level.DEBUG -> 0xFF616161.toInt()
            }
            holder.levelView.text = entry.level.name
            holder.levelView.setTextColor(color)
            holder.levelView.background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = dp(4).toFloat()
                setColor(adjustAlpha(color, 0.1f))
            }
            
            holder.itemView.setBackgroundColor(if (isSelectingLogs && selectedLogIndices.contains(position)) adjustAlpha(getThemeColor(com.google.android.material.R.attr.colorPrimary), 0.2f) else Color.TRANSPARENT)
            
            holder.itemView.setOnClickListener {
                if (isSelectingLogs) {
                    if (selectedLogIndices.contains(position)) {
                        selectedLogIndices.remove(position)
                    } else {
                        selectedLogIndices.add(position)
                    }
                    notifyItemChanged(position)
                }
            }
            
            holder.itemView.setOnLongClickListener {
                if (!isSelectingLogs) {
                    val time = copyTimeFormatter.format(Date(entry.timestamp))
                    val src = if (entry.source.isEmpty()) "" else "[${entry.source}] "
                    copyToClipboard("$time ${entry.level.name} $src${entry.message}")
                    Toast.makeText(this@DebugActivity, "Copied to clipboard", Toast.LENGTH_SHORT).show()
                    true
                } else false
            }
        }

        override fun getItemCount() = entries.size

        private fun adjustAlpha(color: Int, factor: Float): Int {
            val alpha = (Color.alpha(color) * factor).toInt()
            val red = Color.red(color)
            val green = Color.green(color)
            val blue = Color.blue(color)
            return Color.argb(alpha, red, green, blue)
        }

        inner class ViewHolder(
            view: View,
            val levelView: TextView,
            val timeView: TextView,
            val sourceView: TextView,
            val messageView: TextView
        ) : RecyclerView.ViewHolder(view)
    }

    // MARK: - Service Binding

    private fun bindPlaybackService() {
        val intent = Intent(this, PlaybackService::class.java)
        bindService(intent, connection, Context.BIND_AUTO_CREATE)
    }

    // MARK: - Auto Refresh

    private fun startAutoRefresh() {
        refreshTimer = Handler(Looper.getMainLooper())
        refreshTimer?.post(object : Runnable {
            override fun run() {
                refreshCurrentTab()
                refreshTimer?.postDelayed(this, 2000)
            }
        })
    }

    private fun stopAutoRefresh() {
        refreshTimer?.removeCallbacksAndMessages(null)
        refreshTimer = null
    }

    private fun refreshCurrentTab() {
        when (currentTab) {
            0 -> refreshPlaybackTab()
            1 -> refreshInfoTab()
            2 -> if (!isSelectingLogs) applyLogFilter()
        }
    }
}
