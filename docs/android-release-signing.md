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

## Build the three release APKs

After the four secrets are saved and the new SHA-1 is registered in Google Cloud, open the repository's **Actions** tab, select **Build Alvzyo Customer, Driver and Admin Release APKs**, and choose **Run workflow** on `main`.

The workflow produces one universal release APK per app. It uses a monotonically increasing Android build number and the same permanent keystore for all three apps. Keep at least two offline backups of `alvzyo-release.jks` and the passwords. Losing the keystore means future APKs cannot update installations signed with it.

## First installation after migration

The earlier test APKs were signed with a temporary debug certificate. Android will not install a differently signed APK as an in-place update. Uninstall those earlier QA/test installations once, then install the three new release APKs. After that one-time migration, future APKs signed with this same keystore can update the installed apps normally.
