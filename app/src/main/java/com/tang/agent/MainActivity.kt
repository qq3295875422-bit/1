package com.tang.agent

import android.app.Application
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                val vm: AgentViewModel = viewModel()
                TangAgentApp(vm)
            }
        }
    }
}

data class ChatMessage(val role: String, val content: String)
data class ModelConfig(val apiKey: String, val baseUrl: String, val model: String)

class AgentViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences("tang_agent", Context.MODE_PRIVATE)

    var apiKey by mutableStateOf(prefs.getString("api_key", "") ?: "")
    var baseUrl by mutableStateOf(prefs.getString("base_url", "https://api.deepseek.com") ?: "https://api.deepseek.com")
    var model by mutableStateOf(prefs.getString("model", "deepseek-chat") ?: "deepseek-chat")
    var input by mutableStateOf("")
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    val messages = mutableStateListOf<ChatMessage>()

    init { loadMessages() }

    fun saveSettings() {
        prefs.edit()
            .putString("api_key", apiKey.trim())
            .putString("base_url", baseUrl.trim().ifBlank { "https://api.deepseek.com" })
            .putString("model", model.trim().ifBlank { "deepseek-chat" })
            .apply()
    }

    fun newChat() {
        messages.clear()
        error = null
        saveMessages()
    }

    fun send() {
        val text = input.trim()
        if (text.isBlank() || loading) return
        if (apiKey.isBlank()) {
            error = "先去设置里填 API Key。"
            return
        }

        messages.add(ChatMessage("user", text))
        input = ""
        loading = true
        error = null
        saveMessages()

        viewModelScope.launch {
            try {
                val reply = LlmClient.complete(ModelConfig(apiKey, baseUrl, model), messages.toList())
                messages.add(ChatMessage("assistant", reply))
                saveMessages()
            } catch (e: Exception) {
                error = e.message ?: "请求失败"
            } finally {
                loading = false
            }
        }
    }

    private fun loadMessages() {
        runCatching {
            val arr = JSONArray(prefs.getString("messages", "[]") ?: "[]")
            messages.clear()
            for (i in 0 until arr.length()) {
                val item = arr.getJSONObject(i)
                messages.add(ChatMessage(item.optString("role"), item.optString("content")))
            }
        }
    }

    private fun saveMessages() {
        val arr = JSONArray()
        messages.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
        prefs.edit().putString("messages", arr.toString()).apply()
    }
}

object LlmClient {
    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(90, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    suspend fun complete(config: ModelConfig, messages: List<ChatMessage>): String = withContext(Dispatchers.IO) {
        val json = JSONObject()
            .put("model", config.model.trim())
            .put("stream", false)
            .put("messages", JSONArray().also { arr ->
                messages.forEach { arr.put(JSONObject().put("role", it.role).put("content", it.content)) }
            })

        val req = Request.Builder()
            .url("${config.baseUrl.trim().trimEnd('/')}/chat/completions")
            .addHeader("Authorization", "Bearer ${config.apiKey.trim()}")
            .addHeader("Content-Type", "application/json")
            .post(json.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()

        client.newCall(req).execute().use { res ->
            val text = res.body?.string().orEmpty()
            if (!res.isSuccessful) throw IllegalStateException("HTTP ${res.code}: ${text.take(300)}")
            JSONObject(text).getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content")
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TangAgentApp(vm: AgentViewModel) {
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    var screen by remember { mutableStateOf("chat") }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet {
                Spacer(Modifier.height(18.dp))
                Text("Tang Agent", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(24.dp, 10.dp))
                DrawerButton("收藏", screen == "favorites") { screen = "favorites"; scope.launch { drawerState.close() } }
                DrawerButton("电脑", screen == "computer") { screen = "computer"; scope.launch { drawerState.close() } }
                DrawerButton("项目", screen == "projects") { screen = "projects"; scope.launch { drawerState.close() } }
                DrawerButton("今天", screen == "chat") { screen = "chat"; scope.launch { drawerState.close() } }
                DrawerButton("技能", screen == "skills") { screen = "skills"; scope.launch { drawerState.close() } }
                Divider(Modifier.padding(vertical = 8.dp))
                DrawerButton("设置", screen == "settings") { screen = "settings"; scope.launch { drawerState.close() } }
            }
        }
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(if (screen == "chat") vm.model else titleFor(screen)) },
                    navigationIcon = { TextButton(onClick = { scope.launch { drawerState.open() } }) { Text("☰") } },
                    actions = {
                        if (screen == "chat") TextButton(onClick = { vm.newChat() }) { Text("新建") }
                        TextButton(onClick = { screen = "settings" }) { Text("设置") }
                    }
                )
            },
            bottomBar = { if (screen == "chat") ChatInputBar(vm) }
        ) { padding ->
            when (screen) {
                "chat" -> ChatScreen(vm, padding)
                "settings" -> SettingsScreen(vm, padding)
                "skills" -> SkillsScreen(padding)
                else -> PlaceholderScreen(titleFor(screen), padding)
            }
        }
    }
}

@Composable
private fun DrawerButton(text: String, selected: Boolean, onClick: () -> Unit) {
    NavigationDrawerItem(label = { Text(text) }, selected = selected, onClick = onClick, modifier = Modifier.padding(horizontal = 12.dp))
}

private fun titleFor(screen: String) = when (screen) {
    "favorites" -> "收藏"
    "computer" -> "电脑"
    "projects" -> "项目"
    "skills" -> "技能"
    "settings" -> "设置"
    else -> "Tang Agent"
}

@Composable
fun ChatScreen(vm: AgentViewModel, padding: PaddingValues) {
    val listState = rememberLazyListState()
    LaunchedEffect(vm.messages.size, vm.loading) {
        val last = vm.messages.lastIndex
        if (last >= 0) listState.animateScrollToItem(last)
    }

    Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 12.dp)) {
        if (vm.messages.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text("今天能帮到你什么吗？", style = MaterialTheme.typography.headlineSmall)
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(vertical = 12.dp),
            ) {
                items(vm.messages) { MessageBubble(it) }
                if (vm.loading) item { Text("正在思考…", modifier = Modifier.padding(8.dp)) }
            }
        }
        vm.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(vertical = 6.dp)) }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage) {
    val isUser = message.role == "user"
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start) {
        Surface(shape = RoundedCornerShape(18.dp), tonalElevation = if (isUser) 3.dp else 1.dp, modifier = Modifier.fillMaxWidth(if (isUser) 0.82f else 0.92f)) {
            Text(message.content, modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp), style = MaterialTheme.typography.bodyLarge)
        }
    }
}

@Composable
fun ChatInputBar(vm: AgentViewModel) {
    Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = vm.input,
            onValueChange = { vm.input = it },
            modifier = Modifier.weight(1f),
            placeholder = { Text("输入消息…") },
            minLines = 1,
            maxLines = 5,
        )
        Spacer(Modifier.width(8.dp))
        Button(onClick = { vm.send() }, enabled = !vm.loading) { Text("发送") }
    }
}

@Composable
fun SettingsScreen(vm: AgentViewModel, padding: PaddingValues) {
    Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("集中管理模型、Bots、技能和工具能力", style = MaterialTheme.typography.titleMedium)
        Text("模型服务", style = MaterialTheme.typography.titleSmall)
        OutlinedTextField(vm.apiKey, { vm.apiKey = it }, Modifier.fillMaxWidth(), label = { Text("API Key") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
        OutlinedTextField(vm.baseUrl, { vm.baseUrl = it }, Modifier.fillMaxWidth(), label = { Text("Base URL") }, singleLine = true)
        OutlinedTextField(vm.model, { vm.model = it }, Modifier.fillMaxWidth(), label = { Text("默认模型") }, singleLine = true)
        Button(onClick = { vm.saveSettings() }, modifier = Modifier.fillMaxWidth()) { Text("保存模型设置") }
        Divider()
        SettingRow("Bots 管理", "后续：人格提示词 + 默认模型 + 可用工具")
        SettingRow("技能", "后续：读文件、写文件、搜索文件、联网搜索")
        SettingRow("知识库", "后续：文档切片、全文搜索、向量检索")
        SettingRow("MCP", "后续：通过电脑或云端桥接 MCP Server")
        SettingRow("定时任务", "后续：定时调用 Bot 执行任务")
        SettingRow("后台运行", "后续：前台服务 + 通知保活")
        SettingRow("Agent 工作区", "后续：选择本地文件夹作为工作目录")
    }
}

@Composable
private fun SettingRow(title: String, desc: String) {
    Surface(shape = RoundedCornerShape(16.dp), tonalElevation = 1.dp, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Text(desc, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
fun SkillsScreen(padding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("需要先配置工作区", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(10.dp))
            Text("Skills 现在保存在你的工作区目录里。下一版接入 Android 文件夹选择、文件读写和工具调用。")
            Spacer(Modifier.height(16.dp))
            Button(onClick = { }) { Text("去配置工作区") }
        }
    }
}

@Composable
fun PlaceholderScreen(title: String, padding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        Text("$title 功能先占位，下一版再接真实数据。")
    }
}
