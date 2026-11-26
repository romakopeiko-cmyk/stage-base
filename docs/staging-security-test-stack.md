# Ізольовані перевірки Stage Base Staging

Тести використовують тільки синтетичні записи й локальні ключі Supabase. Не підключайте цей каталог до хмарного проєкту.

## Codespaces

1. Відкрийте гілку PR №31 у Codespaces із Docker, Node 22 або новішим і вільним місцем для образів Supabase. Перевірте `docker info` і `df -h`. Використовуйте поточну квоту організації. Припиніть створення, якщо GitHub показує, що за нього буде стягнуто плату.
2. Встановіть Supabase CLI 2.78.1 або новішу сумісну версію. Створіть поза репозиторієм приватний каталог. Виконайте в ньому `supabase init`. У `supabase/config.toml` задайте `project_id = "stage-security-local"` і `[db] major_version = 17`. Збережіть стандартний порт API 54321.
3. Отримайте від відповідального за Staging приватний пакет **20 SQL-міграцій** з історії Staging. Скопіюйте їх до локального `supabase/migrations/`, потім додайте три SQL-міграції PR №31 у порядку версій. Дампи, SQL з приватної історії та облікові дані не додавайте до Git.
4. Виконайте `supabase start -x studio,imgproxy,inbucket,edge-runtime,logflare,vector,supavisor,realtime`. Переконайтеся, що до роботи запущено локальні Auth, REST, Storage і PostgreSQL. Після запуску нової копії або повторного прогону застосуйте `supabase db reset --local` лише до цього локального проєкту.
5. З каталогу локального проєкту завантажте його змінні через `set -a; source <(supabase status -o env); set +a`. Не друкуйте значення змінних. Запустіть `node /path/to/repository/tools/security/staging-api-matrix.mjs`.
6. Виконайте `staging-postgres-matrix.sql`, `staging-acl-check.sql` і `staging-task-authorization-check.sql` через `docker exec -i supabase_db_stage-security-local psql -X -U postgres -v ON_ERROR_STOP=1`. Перший SQL-тест сам відкочує записи. API-тест залишає синтетичні записи тільки в локальному стеку. Після прогону виконайте `supabase db reset --local` або вимкніть стек і видаліть його одноразові томи.

## GitHub Actions

На одноразовому Docker runner послідовно виконайте кроки 2–6. Приватну базову історію подавайте як окремий захищений вхід CI з обмеженням доступу. Не запускайте job з таким входом для непідтверджених PR із форків і не додавайте його до публічних артефактів. Після підготовки вхідних міграцій jobs не потребують доступу до хмарного Supabase.
