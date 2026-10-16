import Foundation
import Darwin

final class HUDLauncher {
    static let shared = HUDLauncher()
    
    private init() {}
    
    func launchHUD() {
        guard let execURL = Bundle.main.executableURL else { return }
        let path = execURL.path
        
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(execURL.lastPathComponent),
            strdup("-hud"),
            nil
        ]
        defer {
            for arg in argv {
                if let arg = arg { free(arg) }
            }
        }
        
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        
        if var a = attr {
            posix_spawnattr_set_persona_np(&a, 99, UInt32(POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE))
            posix_spawnattr_set_persona_uid_np(&a, 0)
            posix_spawnattr_set_persona_gid_np(&a, 0)
            posix_spawn(&pid, path, nil, &a, &argv, nil)
            posix_spawnattr_destroy(&a)
        }
    }
    
    func killAllHUD() {
        let task = NSTask()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Ascent"]
        do {
            try task.launch()
            task.waitUntilExit()
        } catch {}
    }
}
