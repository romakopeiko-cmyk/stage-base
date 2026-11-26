# Запрошення Stage Base Staging

Відкрийте [Authentication → URL Configuration](https://supabase.com/dashboard/project/cnkwvrxlvvtmfiubtyks/auth/url-configuration). У **Site URL** установіть `https://romakopeiko-cmyk.github.io/stage-base/staging/`. У **Redirect URLs** додайте ту саму адресу дослівно, включно з кінцевою косою рискою.

Відкрийте [Authentication → Email Templates](https://supabase.com/dashboard/project/cnkwvrxlvvtmfiubtyks/auth/templates). Для шаблону **Invite user** встановіть **Subject** на `Запрошення до Stage Base Staging`, а в **Body** вставте HTML із [шаблону запрошення](../staging/invitation-email.html). Збережіть. Кнопка відкриває Staging за фіксованою адресою. Застосунок обмінює одноразовий хеш на сесію Supabase Auth, прибирає хеш з адресного рядка, перевіряє стан запрошення та пропонує встановити пароль.

Надішліть запрошення повторно з «Профіль → Команда». Раніше відправлені листи містять попередні посилання. Після відкликання або закінчення строку запрошення профіль не активується.

Під час повторного надсилання для підтвердженої адреси Supabase Auth може використати **Magic link**. Він спирається на налаштовані Site URL і Redirect URLs. Повідомлення про надсилання означає, що сервіс прийняв запит. Доставку слід перевірити у вхідних повідомленнях.

## Якщо редактор шаблонів просить власний SMTP

Чинне надсилання можна залишити ввімкненим, доки не підготовлено поштові параметри. У проєкті **Stage Base Staging** відкрийте [Authentication → SMTP Settings](https://supabase.com/dashboard/project/cnkwvrxlvvtmfiubtyks/auth/smtp). Увімкніть **Enable Custom SMTP** лише після отримання параметрів чинного поштового провайдера. Заповніть **Sender email**, **Sender name** (`Stage Base by Stage Show Company`), **Host**, **Port**, **Username** та **Password** відповідно до даних провайдера. SMTP-пароль вводьте в Dashboard.

Після налаштування у шаблоні **Invite user** встановіть тему `Запрошення до Stage Base` та вставте HTML із репозиторію. Надішліть одне тестове запрошення й перевірте отримання листа та перший вхід перед масовим надсиланням.
