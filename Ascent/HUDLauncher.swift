import Foundation
import Darwin

final class HUDLauncher {
    static let shared = HUDLauncher()
    
    private init() {}
    
    func launchHUD() {
        let execURL = Bundle.main.executableURL
        guard let path = execURL?.path else { return }
        
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(execURL?.lastPathComponent ?? "Ascent"),
            strdup("-hud"),
            nil
        ]
        defer {
            for arg in argv {
                if let arg = arg { free(arg) }
            }
        }
        
        var attr: posix_spawnattr_t = nil
        posix_spawnattr_init(&attr)
        
        if let a = attr {
            posix_spawnattr_set_persona_np(&a, 99, UInt32(POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE))
            posix_spawnattr_set_persona_uid_np(&a, 0)
            posix_spawnattr_set_persona_gid_np(&a, 0)
            posix_spawn(&pid, path, nil, &a, &argv, environ)
            posix_spawnattr_destroy(&a)
        }
    }
    
    func killAllHUD() {
        let _ = Process.launchedProcess(launchPath: "/usr/bin/killall", arguments: ["Ascent"])
    }
}
