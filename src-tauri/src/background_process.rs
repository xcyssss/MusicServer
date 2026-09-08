use std::process::{Command, Stdio};

/// Prevent console allocation at process creation; hiding PowerShell later can flash.
pub fn command(program: &str) -> Command {
    let mut command = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

#[cfg(all(test, windows))]
mod tests {
    #[test]
    fn powershell_has_no_console_and_can_return_output() {
        // Query the child's actual console, rather than just checking configured flags.
        let output = super::command("powershell.exe")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ConsoleProbe { [DllImport(\"kernel32.dll\")] public static extern IntPtr GetConsoleWindow(); }'; if ([ConsoleProbe]::GetConsoleWindow() -ne [IntPtr]::Zero) { exit 7 }; Write-Output 'background-ready'",
            ])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output()
            .unwrap();
        assert!(output.status.success(), "{:?}", output);
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).trim(),
            "background-ready"
        );
    }
}
