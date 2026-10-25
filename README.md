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

**Desktop view (open this — nothing to type):** the log notice titled **Desktop view**, and the same `trycloudflare.com` URL at the top of the Summary. No username, no VNC password, and no basic-auth. The page is titled “macOS desktop — view only”. It shows the real console (menu bar, Finder, wallpaper) and updates about every second from `screencapture`. It does not speak VNC, so the Apple Screen Sharing login dialog is not on this page. View only: mouse and keyboard stay on the browser shell or noVNC.

**Browser desktop (noVNC, works from Windows Chrome):** open the `trycloudflare.com` link that ends in `vnc.html`. Password: `VNC_PASSWORD`. Screen Sharing also offers Apple authentication (RFB types 30 and 33). noVNC then shows a username and password dialog, and `VNC_PASSWORD` / `VNC_USER_PASSWORD` do not answer it. Use the desktop view above to see the screen. When noVNC does connect, a logged-in desktop (menu bar and Finder) should be visible within about a minute, not a black or dark-grey screen.

**Native VNC client (TightVNC or RealVNC Viewer):** host and port from the ngrok TCP line. TightVNC wants `host::port` (two colons). Password: `VNC_PASSWORD`. If the client asks for a macOS user, use `runner` with `VNC_USER_PASSWORD`.

**Browser shell:** the ttyd `trycloudflare.com` link. Basic auth user `runner`, password `VNC_USER_PASSWORD`. Public tmate servers (`ssh.tmate.io`) have been offline since July 2025, so ttyd is the shell that comes up. The workflow still tries tmate and prints an SSH or web line when a server answers. Mouse and keyboard for a shell stay here; the desktop view does not take input.

### 4. On the desktop

The desktop is the `runner` account that already owns the Aqua session. Google Chrome is installed at `/Applications/Google Chrome.app`. The DMG is on that user's Desktop and at `/Users/Shared/SunoCoverBotSetup-mac.dmg`. `CONNECT.txt` in those same places repeats the addresses.

The setup step does not publish the tunnel when the console is a login window. The job log line `GUI check:` names the console user, whether Finder is running for that user, and the screenshot brightness. A near-black screenshot fails the job. A black VNC sample is ignored when Screen Sharing offers Apple authentication (RFB types 30 or 33) and the screenshot is already a desktop; that sample is not the console picture, and setup does not type a password into the login window over a desktop that is already up. A root `loginwindow` beside Finder is left running: stopping it moved the console to `root`. Setup does not open a short VNC probe once that desktop is already up, because the probe was followed by a root `loginwindow` and a console flip. Screen Sharing is limited to `runner`, and Fast User Switching is turned off. `CGSession` is not on current macOS; the log says so separately from a missing user id. Screen Sharing follows the console, and a black Apple-auth VNC sample is not proof of the desktop, so the tunnel is published only when the console user is `runner`, Finder is `runner`, and the screenshot is not near-black. In the Summary, that same line is how you confirm the desktop was real before you connect. Open the **Desktop view** URL to see that screen with nothing to type. noVNC stays available and can still show the Apple username dialog.

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

1. **תצוגת שולחן בלי סיסמה** — בהודעה **Desktop view** ובסיכום, קישור `trycloudflare.com`. אין שם משתמש, אין סיסמת VNC, ואין basic-auth. העמוד נקרא “macOS desktop — view only” ומראה את המסך (תפריט, Finder, רקע) ומתרענן בערך כל שנייה. צפייה בלבד. עכבר ומקלדת נשארים במעטפת או ב-noVNC. העמוד לא עובר דרך VNC, אז חלון ההתחברות של Apple לא מופיע שם.
2. **דפדפן noVNC** — קישור `trycloudflare.com` עם `vnc.html`. סיסמה: `VNC_PASSWORD`. אם מופיע חלון שם משתמש וסיסמה, זו הזדהות Apple (RFB 30/33), והסודות לא עונים לה. לצפייה במסך פותחים את תצוגת השולחן למעלה.
3. **לקוח VNC** (TightVNC / RealVNC) — כתובת ngrok. ב-TightVNC כותבים `host::port`. אם מתבקשים משתמש: `runner`, סיסמה `VNC_USER_PASSWORD`.
4. **מעטפת בדפדפן** — קישור ttyd. משתמש `runner`, סיסמה `VNC_USER_PASSWORD`. שרתי tmate הציבוריים כבויים מיולי 2025; ttyd הוא המעטפת שעולה.

Chrome כבר מותקן, אצל המשתמש `runner`. אם Gatekeeper חוסם: System Settings → Privacy & Security → Open Anyway.

שלב ה-setup נכשל במקום לפרסם מנהרה אם הקונסולה היא חלון התחברות שחור. בשורת `GUI check:` בלוג: משתמש הקונסולה, האם Finder רץ עבורו, ובהירות צילום המסך. `loginwindow` של root נשאר רץ אם Finder והצילום הם שולחן העבודה של `runner`. לא נפתח חיבור VNC קצר אחרי שהשולחן כבר חי, כי החיבור הקודם הקדים מעבר של הקונסולה ל-root. המנהרה מתפרסמת רק כשמשתמש הקונסולה הוא `runner`. את המסך רואים בתצוגת Desktop view בלי להקליד סיסמה. noVNC נשאר, ויכול עדיין להציג את חלון ההתחברות של Apple.

הלוג ציבורי. מבטלים את הריצה בסיום. ריצה חדשה סוגרת את הקודמת.
