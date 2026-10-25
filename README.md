# SunoCoverBot macOS desktop

Free, click-to-start macOS desktop for installing and testing `SunoCoverBotSetup-mac.dmg` and the Chrome extension. The desktop runs on a GitHub-hosted `macos-latest` runner. Keep this repository **public** so macOS Actions minutes stay free. Merge this workflow to `main` before the first run: GitHub shows **Run workflow** for `workflow_dispatch` from the default branch.

No paid Mac cloud and no browser-rental services. The runner is thrown away when the job ends.

## English

### 1. Add secrets

Repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

| Secret | Required | Value |
| --- | --- | --- |
| `VNC_PASSWORD` | Yes | Legacy VNC password. **8 characters or fewer** (macOS keeps the first 8). Letters and digits. This is the password for TightVNC, RealVNC, and the browser desktop. |
| `VNC_USER_PASSWORD` | Yes | macOS password set on the console user (`runner` on GitHub). Avoid a leading `-` and avoid `:`. Used if a client asks for a macOS account, and as the browser-shell basic-auth password. |
| `NGROK_AUTH_TOKEN` | For native VNC | Authtoken from [ngrok](https://dashboard.ngrok.com/get-started/your-authtoken). The free plan is enough. **TCP needs a card saved on the ngrok account; ngrok does not charge that card.** The browser desktop works before the card is saved. |

GitHub masks these values in the log. They are not printed.

### 2. Run

**Actions** → **macOS VNC desktop** → **Run workflow**.

- **minutes**: how long the desktop stays up. Default 90. Allowed range 15–300. The job itself cannot pass 6 hours.
- **download_dmg**: on by default. Downloads `https://46-225-2-111.sslip.io/SunoCoverBotSetup-mac.dmg` onto the Desktop and `/Users/Shared`.

A second run cancels the one that is already open. Cancel the run when you finish so the machine is destroyed.

### 3. Connect

Open the run and read the **Summary**. The same text is in the job log. The log is public, so the tunnel addresses are visible to anyone until you cancel.

**Browser desktop (works from Windows Chrome):** open the `trycloudflare.com` link that ends in `vnc.html`. Password: `VNC_PASSWORD`. Within about a minute of connecting you should see a logged-in macOS desktop (menu bar and Finder), not a black or dark-grey screen. If the page asks for a macOS account, use `runner` and `VNC_USER_PASSWORD`.

**Native VNC client (TightVNC or RealVNC Viewer):** host and port from the ngrok TCP line. TightVNC wants `host::port` (two colons). Password: `VNC_PASSWORD`. If the client asks for a macOS user, use `runner` with `VNC_USER_PASSWORD`.

**Browser shell:** second `trycloudflare.com` link (ttyd). Basic auth user `runner`, password `VNC_USER_PASSWORD`. Public tmate servers (`ssh.tmate.io`) have been offline since July 2025, so ttyd is the shell that comes up. The workflow still tries tmate and prints an SSH or web line when a server answers.

### 4. On the desktop

The desktop is the `runner` account that already owns the Aqua session. Google Chrome is installed at `/Applications/Google Chrome.app`. The DMG is on that user's Desktop and at `/Users/Shared/SunoCoverBotSetup-mac.dmg`. `CONNECT.txt` in those same places repeats the addresses.

The setup step does not publish the tunnel when the console is a login window. The job log line `GUI check:` names the console user, whether Finder is running for that user, and the screenshot brightness. A near-black screenshot fails the job. A black VNC sample is ignored when Screen Sharing offers Apple authentication (RFB types 30 or 33) and the screenshot is already a desktop; that sample is not the console picture, and setup does not type a password into the login window over a desktop that is already up. If a root `loginwindow` starts while Finder is still `runner` and the screenshot is a desktop, setup stops that process without logging `runner` out. The tunnel is published only when the console user is `runner` again, Finder is `runner`, and the screenshot is not near-black. In the Summary, that same line is how you confirm the desktop was real before you connect. After you open noVNC, the menu bar and Finder should be visible within about a minute.

Install `SunoCoverBot` from the DMG, then install the Chrome extension in the runner's Chrome. If Gatekeeper blocks the app: **System Settings → Privacy & Security → Open Anyway**.

### Limits

- One desktop at a time. Cancel it when the test is done.
- Input max is 300 minutes. GitHub kills the job at 6 hours.
- Making the repository private turns macOS minutes into billed minutes.

## עברית

שולחן עבודה של macOS לבדיקת ההתקנה של SunoCoverBot, על runner של GitHub Actions. המאגר נשאר **ציבורי** כדי שדקות macOS יישארו בחינם. אחרי מיזוג ל-`main`: Actions → **macOS VNC desktop** → **Run workflow**.

### סודות

Settings → Secrets and variables → Actions → New repository secret.

- `VNC_PASSWORD` — חובה. סיסמת VNC, עד 8 תווים (אותיות וספרות). זו הסיסמה לדפדפן וללקוח VNC.
- `VNC_USER_PASSWORD` — חובה. סיסמת macOS למשתמש `runner` (משתמש הקונסולה). בלי `-` בהתחלה ובלי `:`.
- `NGROK_AUTH_TOKEN` — ל-VNC רגיל (TCP). מפתח חינמי מ-[ngrok](https://dashboard.ngrok.com/get-started/your-authtoken). ל-TCP צריך כרטיס שמור בחשבון ngrok; ngrok לא מחייב את הכרטיס. שולחן העבודה בדפדפן עובד גם בלי הכרטיס.

הערכים לא מופיעים בלוג (GitHub מסתיר סודות).

### הרצה וחיבור

- **minutes** — כמה זמן להשאיר את השולחן פתוח. ברירת מחדל 90, בין 15 ל-300. תקרת GitHub היא 6 שעות.
- **download_dmg** — מסומן כברירת מחדל. מוריד את `SunoCoverBotSetup-mac.dmg` לשולחן העבודה ול-`/Users/Shared`.

בסיכום הריצה (Summary):

1. **דפדפן** — קישור `trycloudflare.com` עם `vnc.html`. סיסמה: `VNC_PASSWORD`. תוך כדקה אמור להופיע שולחן עבודה מחובר (תפריט ו-Finder), לא מסך שחור. אם מתבקשים חשבון macOS: `runner` והסוד `VNC_USER_PASSWORD`.
2. **לקוח VNC** (TightVNC / RealVNC) — כתובת ngrok. ב-TightVNC כותבים `host::port`. אם מתבקשים משתמש: `runner`, סיסמה `VNC_USER_PASSWORD`.
3. **מעטפת בדפדפן** — קישור ttyd. משתמש `runner`, סיסמה `VNC_USER_PASSWORD`. שרתי tmate הציבוריים כבויים מיולי 2025; ttyd הוא המעטפת שעולה.

Chrome כבר מותקן, אצל המשתמש `runner`. אם Gatekeeper חוסם: System Settings → Privacy & Security → Open Anyway.

שלב ה-setup נכשל במקום לפרסם מנהרה אם הקונסולה היא חלון התחברות שחור. בשורת `GUI check:` בלוג: משתמש הקונסולה, האם Finder רץ עבורו, ובהירות צילום המסך. אם עולה `loginwindow` של root בזמן ש-Finder והצילום עדיין שולחן העבודה של `runner`, התהליך הזה נעצר בלי לנתק את `runner`. המנהרה מתפרסמת רק כשמשתמש הקונסולה הוא שוב `runner`. אחרי פתיחת noVNC אמורים לראות את שולחן העבודה תוך כדקה.

הלוג ציבורי. מבטלים את הריצה בסיום. ריצה חדשה סוגרת את הקודמת.
