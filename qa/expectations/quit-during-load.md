# quit-during-load Expectations

Flow: `quit-during-load`

This flow starts a browser tile load, quits the app during the load, and checks for new DiagnosticReports.

## Step Expectations

- `before-quit`: The browser load flow has started and the app is responsive before the scripted quit.
- `diagnosticreports-clean`: No new DiagnosticReports entry appears after quitting during the browser load.

## verified-working Notes

When no finding is filed, record a `verified-working` note that confirms the pre-quit screenshot is readable and the diagnosticreports-clean step passed.
