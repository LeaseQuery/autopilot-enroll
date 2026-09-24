# Autopilot enrollment (FinQuery IT)

Registers a Windows device with Windows Autopilot, applies its group tag, and hands it back to a clean OOBE ready for its user.

## Before you start

- **Only run this on a new device, or one whose data is backed up.** On a device that's already set up, the script erases everything on it.
- Connect the device to the internet: plug in Ethernet, or use the Wi-Fi screen in OOBE.
- Have your phone ready to sign in with your FinQuery account.

## Run it

1. In OOBE, press **Shift + F10**.
2. Type this command and press **Enter**. Always include the `https://`.

   ```
   powershell -c "irm https://raw.githubusercontent.com/LeaseQuery/autopilot-enroll/main/go.ps1 | iex"
   ```

3. Choose the device type, then the country (or, for a test machine, the account type). See [Group tags](#group-tags). If you don't press anything, it continues as a regular US employee.
4. When the QR code appears, scan it with your phone or open the link shown. Enter the code shown on the device, then sign in with your FinQuery account.

   Only continue if your phone says you're signing in to **FinQuery Autopilot Enrollment** and you started the sign-in on the device in front of you.

5. Wait for **ENROLLMENT COMPLETE**. Don't close the window or restart the device before then. The script registers the device, or updates its group tag if it's already registered.
   - A new device restarts into Autopilot.
   - A device that's already set up is reset, then restarts. Press any key during the 30-second countdown to cancel the reset.

If enrollment fails, nothing on the device is changed. Note the message on screen and check the log.

## Group tags

| Device type | Second question | Group tag |
|---|---|---|
| Regular employee *(default)* | United States *(default)* | `US-FinQuery` |
| | Other country | `<CC>-FinQuery`, e.g. `UK-FinQuery` |
| Contractor | United States *(default)* | `US-FinQuery-CTR` |
| | Other country | `<CC>-FinQuery-CTR`, e.g. `ZA-FinQuery-CTR` |
| AlternIT One | *(none)* | `UK-AlternITOne` |
| Test machine | Standard user | `Test-Standard-FinQuery` |
| | Administrator | `Test-Admin-FinQuery` |

- For the United Kingdom, enter `UK`, not `GB`.
- Test tags ask you to confirm, because they exempt the device from security policies.

## From a flash drive

Copy `Enroll-Autopilot-Internal.ps1` next to `Enroll.cmd` on the flash drive.

- **In OOBE:** press **Shift + F10** and type `D:\Enroll`, using the flash drive's letter.
- **On a device that's already set up:** right-click `Enroll.cmd` and choose **Run as administrator**.

## Logs

Logs are saved to `C:\ProgramData\AutopilotEnroll`, or next to the script when it runs from a flash drive. A reset erases them.
