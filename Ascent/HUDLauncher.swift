import Foundation

final class HUDLauncher {
    static let shared = HUDLauncher()
    
    private init() {}
    
    func launchHUD() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/posix_spawn")
        
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(Bundle.main.executableURL?.lastPathComponent ?? "Ascent"),
            strdup("-hud"),
            nil
        ]
        defer {
            for arg in argv {
                if let arg = arg { free(arg) }
            }
        }
        
        var attributes: posix_spawnattr_t = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        posix_spawnattr_set_persona_np(&attributes, 99, UInt32(POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE))
        posix_spawnattr_set_persona_uid_np(&attributes, 0)
        posix_spawnattr_set_persona_gid_np(&attributes, 0)
        
        let result = posix_spawn(&pid, Bundle.main.executableURL!.path, nil, &attributes, &argv, nil)
        if result != 0 {
            // Fallback if posix_spawn fails
            print("Failed to spawn HUD: \(result)")
        }
    }
    
    func killAllHUD() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Ascent"]
        try? task.run()
        task.waitUntilExit()
    }
}
