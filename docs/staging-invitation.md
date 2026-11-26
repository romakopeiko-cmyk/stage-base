# Запрошення Stage Base Staging

Відкрийте [Authentication → URL Configuration](https://supabase.com/dashboard/project/cnkwvrxlvvtmfiubtyks/auth/url-configuration). У **Site URL** установіть `https://romakopeiko-cmyk.github.io/stage-base/staging/`. У **Redirect URLs** додайте ту саму адресу дослівно, включно з кінцевою косою рискою.

Відкрийте [Authentication → Email Templates](https://supabase.com/dashboard/project/cnkwvrxlvvtmfiubtyks/auth/templates). Для шаблону **Invite user** встановіть **Subject** на `Запрошення до Stage Base Staging`, а в **Body** вставте HTML із [шаблону запрошення](../staging/invitation-email.html). Збережіть. Кнопка відкриває Staging за фіксованою адресою. Застосунок обмінює одноразовий хеш на сесію Supabase Auth, прибирає хеш з адресного рядка, перевіряє стан запрошення та пропонує встановити пароль.

Надішліть запрошення повторно з «Профіль → Команда». Раніше відправлені листи містять попередні посилання. Після відкликання або закінчення строку запрошення профіль не активується.

Під час повторного надсилання для підтвердженої адреси Supabase Auth може використати **Magic link**. Він спирається на налаштовані Site URL і Redirect URLs. Повідомлення про надсилання означає, що сервіс прийняв запит. Доставку слід перевірити у вхідних повідомленнях.
