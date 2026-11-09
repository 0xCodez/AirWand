//! Native "Allow ‹device› to control this computer? Code 123 456" confirmation.
//!
//! macOS: an NSAlert via `rfd` with real "Allow" / "Deny" buttons. AppKit requires it on
//! the main thread, so `pairing.rs` routes the request through the event loop.
//! Windows: a top-most `MessageBoxW` (Yes = Allow, No = Deny). It may run on any thread;
//! the pairing thread spawns one so the tray stays responsive. (Custom button labels on
//! Windows would require a comctl32 v6 manifest; Yes/No avoids that dependency.)

/// Shows the dialog and blocks until the user answers. Returns `true` for Allow.
pub fn confirm_pairing(device_name: &str, code_display: &str) -> bool {
    let title = "Orbit — pairing request";
    let message = format!(
        "Allow “{device_name}” to control this computer?\n\nCode {code_display}\n\n\
         Only allow it if your phone shows the same code."
    );
    imp::confirm(title, &message)
}

#[cfg(target_os = "macos")]
mod imp {
    use objc::runtime::{Object, YES};
    use objc::{class, msg_send, sel, sel_impl};
    use rfd::{MessageButtons, MessageDialog, MessageDialogResult, MessageLevel};

    /// An `Accessory` (menu-bar only) app is never active on its own, so a modal alert
    /// would open behind the frontmost app. Bring Orbit forward first (main thread only).
    fn activate_app() {
        unsafe {
            let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
            if !app.is_null() {
                let _: () = msg_send![app, activateIgnoringOtherApps: YES];
            }
        }
    }

    pub fn confirm(title: &str, message: &str) -> bool {
        activate_app();
        let result = MessageDialog::new()
            .set_level(MessageLevel::Warning)
            .set_title(title)
            .set_description(message)
            .set_buttons(MessageButtons::OkCancelCustom("Allow".to_string(), "Deny".to_string()))
            .show();
        match result {
            MessageDialogResult::Custom(label) => label == "Allow",
            MessageDialogResult::Ok | MessageDialogResult::Yes => true,
            MessageDialogResult::Cancel | MessageDialogResult::No => false,
            #[allow(unreachable_patterns)]
            _ => false,
        }
    }
}

#[cfg(windows)]
mod imp {
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        MessageBoxW, IDYES, MB_DEFBUTTON2, MB_ICONQUESTION, MB_SETFOREGROUND, MB_TOPMOST, MB_YESNO,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub fn confirm(title: &str, message: &str) -> bool {
        let text = wide(&format!("{message}\n\nYes = Allow    No = Deny"));
        let caption = wide(title);
        let answer = unsafe {
            MessageBoxW(
                HWND::default(),
                PCWSTR(text.as_ptr()),
                PCWSTR(caption.as_ptr()),
                MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_TOPMOST | MB_SETFOREGROUND,
            )
        };
        answer == IDYES
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    pub fn confirm(title: &str, message: &str) -> bool {
        log::warn!("{title}: no native dialog on this platform, denying.\n{message}");
        false
    }
}
