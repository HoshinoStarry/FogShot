function(replace_streamer_source relative before after)
  set(path "${upstream}/pc/streamer/src/${relative}")
  file(READ "${path}" original)
  string(FIND "${original}" "${before}" position)
  if(position LESS 0)
    message(FATAL_ERROR "Unexpected upstream source in ${relative}")
  endif()
  string(REPLACE "${before}" "${after}" modified "${original}")
  file(WRITE "${path}" "${modified}")
endfunction()

replace_streamer_source(settings.h "bool allowRemote = true;" "bool allowRemote = false;")
replace_streamer_source(settings.h "bool autoRegisterSteamVrDriver = true;" "bool autoRegisterSteamVrDriver = false;")
replace_streamer_source(settings.h "bool switchDefaultAudio = true;" "bool switchDefaultAudio = false;")
replace_streamer_source(app.cpp [=[    SettingsStore::Get().Load();]=] [=[    SettingsStore::Get().Load();
    SettingsStore::Get().Update([](Settings& s) {
        s.requireApproval = true;
        s.autoRegisterSteamVrDriver = false;
        s.switchDefaultAudio = false;
    });]=])
replace_streamer_source(app.cpp
  [=[{"deviceName", rcs::HeadsetName(hello.model).empty() ? hello.deviceName : rcs::HeadsetName(hello.model)},]=]
  [=[{"deviceName", hello.deviceName.empty() ? rcs::HeadsetName(hello.model) : hello.deviceName},]=])
replace_streamer_source(session/client_session.h
  [=[return name.empty() ? m_hello.deviceName : name;]=]
  [=[return m_hello.deviceName.empty() ? name : m_hello.deviceName;]=])
replace_streamer_source(settings.cpp
  [=[HeadsetName(d.model).empty() ? d.name : HeadsetName(d.model)]=]
  [=[d.name.empty() ? HeadsetName(d.model) : d.name]=])
replace_streamer_source(settings.cpp
  [=[if (!mapped.empty()) td.name = mapped;]=]
  [=[if (td.name.empty()) td.name = mapped;]=])

# Install one-time approval state before the network thread can observe the approval.
replace_streamer_source(app.cpp [=[        if (type == "approve")
            m_server.Approve(id, m.value("remember", true));
        else
            m_server.Deny(id);
        std::lock_guard lock(m_uiMutex);
        if (type == "approve" && !m.value("remember", true)) m_noRemember.insert(id);
        m_pendingApproval = nullptr;]=] [=[        const bool remember = m.value("remember", true);
        {
            std::lock_guard lock(m_uiMutex);
            if (type == "approve" && !remember) m_noRemember.insert(id);
            m_pendingApproval = nullptr;
        }
        if (type == "approve")
            m_server.Approve(id, remember);
        else
            m_server.Deny(id);]=])

# An independent profile keeps this host's settings and keys separate from a stock Streamer.
replace_streamer_source(util.cpp "#include <fstream>" "#include <cstdlib>\n#include <fstream>")
replace_streamer_source(util.cpp [=[    static const std::filesystem::path dir = [] {
        PWSTR path = nullptr;]=] [=[    static const std::filesystem::path dir = [] {
        if (const auto* overridePath = _wgetenv(L"FOGSHOT_HOST_DATA_DIR"); overridePath && *overridePath) {
            return std::filesystem::path(overridePath);
        }
        PWSTR path = nullptr;]=])
replace_streamer_source(util.cpp [=[ / L"RinCast";]=] [=[ / L"FogShot Streamer";]=])
replace_streamer_source(platform/mac/util_mac.mm
  [=[        const auto p = Home() / "Library/Application Support/RinCast";]=]
  [=[        const auto* overridePath = std::getenv("FOGSHOT_HOST_DATA_DIR");
        const auto p = overridePath && *overridePath ? std::filesystem::path(overridePath)
                                                    : Home() / "Library/Application Support/FogShot Streamer";]=])

# Keep the desktop encoder and session implementation while excluding VR entry points.
replace_streamer_source(session/client_session.cpp [=[        SendMonitors();
        StartVr();
        UpdateAudio();]=] [=[        SendMonitors();
        UpdateAudio();]=])
replace_streamer_source(session/client_session.cpp [=[    if (type == rc::msg::kLaunchSteamVr) return LaunchSteamVr();]=]
  [=[    if (type == rc::msg::kLaunchSteamVr || type == rc::msg::kLaunchGame || type == rc::msg::kListGames) return;]=])
replace_streamer_source(session/client_session.cpp [=[void ClientSession::StartVr() {]=] [=[void ClientSession::StartVr() {
    return; // FogShot hosts desktop streams only.]=])
