# Alvzyo Android release signing

Alvzyo Customer, Driver and Admin APKs must always be signed with the same permanent keystore. Never commit the keystore or its passwords to this repository.

## Create the permanent keystore on Windows

Open PowerShell on the Windows computer where you will keep the backup. Android Studio installs Java's `keytool`; if it is not on PATH, the command below checks the standard Android Studio location.

```powershell
$KeytoolCommand = Get-Command keytool -ErrorAction SilentlyContinue
if ($KeytoolCommand) {
    $Keytool = $KeytoolCommand.Source
} else {
    $Keytool = "$env:ProgramFiles\Android\Android Studio\jbr\bin\keytool.exe"
}
if (-not (Test-Path $Keytool)) {
    throw "keytool was not found. Install Android Studio or configure a JDK."
}

$KeystorePath = "$env:USERPROFILE\alvzyo-release.jks"
& $Keytool -genkeypair -v -keystore $KeystorePath -storetype JKS -alias alvzyo-release -keyalg RSA -keysize 4096 -validity 10000
```

Keytool prompts for a keystore password and certificate details. Use a strong, unique password and keep it in a password manager. When it asks for the key password, press Enter to use the same password as the keystore password. The GitHub secret `ANDROID_KEY_PASSWORD` must then have the same value as `ANDROID_KEYSTORE_PASSWORD`.

## Copy the signing certificate fingerprint

```powershell
& $Keytool -list -v -keystore $KeystorePath -alias alvzyo-release | Select-String "SHA1:"
```

Keep the SHA-1 fingerprint. In Google Cloud Console, open the three Android OAuth clients and add this release certificate SHA-1 to each client, keeping each package name unchanged:

- `com.alvzyo.ride.customer`
- `com.alvzyo.ride.driver`
- `com.alvzyo.ride.admin`

If Google Cloud does not let you add the fingerprint to an existing client, create a replacement Android OAuth client for that same package and new SHA-1. In that case, also add the replacement Android client IDs to the Google provider's Client IDs list in Supabase Auth. Keep the Web OAuth client ID and Web client secret configured as they are.

## Add the keystore to GitHub Actions secrets

Convert the keystore to one-line Base64 and copy it to the clipboard:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes($KeystorePath)) | Set-Clipboard
```

In GitHub, open **Alvzyo-ride → Settings → Secrets and variables → Actions → New repository secret**. Add these four repository secrets:

| Secret name | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | The Base64 text copied to the clipboard |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore password |
| `ANDROID_KEY_ALIAS` | `alvzyo-release` |
| `ANDROID_KEY_PASSWORD` | The same password, because the key password was set to the keystore password |

Do not paste the keystore or either password into a chat, issue, source file, or commit.

## Configure Firebase Cloud Messaging for all three apps

The apps use Firebase Cloud Messaging for ride offers and account notifications. The previous QA workflow supplied empty Firebase values, so those builds did not have push notifications configured. The release workflow now requires real Firebase configuration for each Android app.

Use the **same new Google Cloud project** that contains the Web and Android OAuth clients:

1. Open the Firebase Console and add Firebase to that existing Google Cloud project (or select it if it is already a Firebase project).
2. In Project settings → General, register three Android apps using these exact package names:
   - `com.alvzyo.ride.customer`
   - `com.alvzyo.ride.driver`
   - `com.alvzyo.ride.admin`
3. For each registered app, copy its Firebase App ID. The API key, Project ID and Messaging Sender ID are shared by all three apps.
4. In Google Cloud Console, ensure the **Firebase Cloud Messaging API** is enabled for this project.
5. In Firebase Console → Project settings → Service accounts, generate a new private key JSON for a service account. In Google Cloud IAM, ensure that service account has the **Firebase Cloud Messaging API Admin** role so the Supabase Edge Function can send messages.

Add these six GitHub Actions repository secrets:

| Secret name | Value |
|---|---|
| `FIREBASE_API_KEY` | Firebase project's Web API key from Project settings |
| `FIREBASE_PROJECT_ID` | Firebase/Google Cloud project ID |
| `FIREBASE_MESSAGING_SENDER_ID` | Firebase project's numeric Messaging Sender ID |
| `FIREBASE_APP_ID_CUSTOMER` | Firebase App ID for `com.alvzyo.ride.customer` |
| `FIREBASE_APP_ID_DRIVER` | Firebase App ID for `com.alvzyo.ride.driver` |
| `FIREBASE_APP_ID_ADMIN` | Firebase App ID for `com.alvzyo.ride.admin` |

In Supabase Dashboard → Project → Edge Functions → Secrets, add **`FCM_SERVICE_ACCOUNT_JSON`** with the complete contents of the service-account JSON file. Keep this private key only in Supabase secrets; do not add it to GitHub, the app, or this repository. The deployed `send-push` function reads this secret to authenticate with FCM.

## Build the three release APKs

After the four secrets are saved and the new SHA-1 is registered in Google Cloud, open the repository's **Actions** tab, select **Build Alvzyo Customer, Driver and Admin Release APKs**, and choose **Run workflow** on `main`.

The workflow produces one universal release APK per app. It uses a monotonically increasing Android build number and the same permanent keystore for all three apps. Keep at least two offline backups of `alvzyo-release.jks` and the passwords. Losing the keystore means future APKs cannot update installations signed with it.

## First installation after migration

The earlier test APKs were signed with a temporary debug certificate. Android will not install a differently signed APK as an in-place update. Uninstall those earlier QA/test installations once, then install the three new release APKs. After that one-time migration, future APKs signed with this same keystore can update the installed apps normally.
