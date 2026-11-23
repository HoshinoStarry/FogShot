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
