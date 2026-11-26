'use strict';

function openTaskDetails(task) {
  modal.innerHTML = `<h2>${esc(taskNumber(task.id))} · ${esc(task.title)}</h2>
    <div id="task-detail-content" aria-live="polite">Завантаження…</div>
    <button class="full" type="button" onclick="modal.close()">Закрити</button>`;
  modal.showModal();
  const content = modal.querySelector('#task-detail-content');
  const mine = !task.owner_id || task.owner_id === me.id;

  async function load() {
    try {
      const [comments, steps, history] = await Promise.all([
        take(db.from('stage_task_comments').select('id,author_id,body,created_at')
          .eq('task_id', task.id).order('id', { ascending: false }).limit(100)),
        take(db.from('stage_task_steps').select('id,title,is_done')
          .eq('task_id', task.id).order('id').limit(100)),
        take(db.from('stage_task_history').select('id,changes,created_at')
          .eq('task_id', task.id).order('id', { ascending: false }).limit(30)),
      ]);
      if (!content.isConnected || !modal.open) return;
      content.innerHTML = `
        <h3>Підзавдання</h3><div id="task-steps"></div>
        ${mine ? '<form data-action="step"><label>Нове підзавдання<input name="text" maxlength="180" required></label><button class="full" type="submit">Додати</button></form>' : ''}
        <h3>Коментарі</h3><div id="task-comments"></div>
        <form data-action="comment"><label>Написати коментар<textarea name="text" maxlength="4000" required></textarea></label><button class="full" type="submit">Надіслати</button></form>
        <details><summary>Історія змін</summary><div id="task-history"></div></details>`;
      const stepList = content.querySelector('#task-steps');
      for (const step of steps) {
        const item = document.createElement('label');
        const check = document.createElement('input');
        check.type = 'checkbox';
        check.style.width = 'auto';
        check.checked = step.is_done;
        check.disabled = !mine;
        check.onchange = async () => {
          check.disabled = true;
          try {
            await take(db.from('stage_task_steps').update({ is_done: check.checked })
              .eq('id', step.id).select('id').single());
          } catch (error) {
            check.checked = !check.checked;
            fail(error);
          } finally { check.disabled = false; }
        };
        item.append(check, document.createTextNode(' ' + step.title));
        stepList.append(item);
      }
      if (!steps.length) stepList.textContent = 'Підзавдань поки немає.';
      const commentList = content.querySelector('#task-comments');
      for (const comment of comments) {
        const card = document.createElement('article');
        card.className = 'line';
        card.innerHTML = `<small>${comment.author_id === me.id ? 'Ви' : 'Учасник'} · ${esc(taskDate(comment.created_at))}</small>
          <p class="task-comment-body">${esc(comment.body)}</p>`;
        commentList.append(card);
      }
      if (!comments.length) commentList.textContent = 'Коментарів поки немає.';
      const historyList = content.querySelector('#task-history');
      for (const item of history) {
        const line = document.createElement('p');
        const { before, after } = item.changes || {};
        const change = !before ? 'Створено' : before.status !== after?.status ?
          'Статус: ' + (taskStatuses[before.status] || '—') + ' → ' + (taskStatuses[after?.status] || '—') : 'Оновлено';
        line.textContent = taskDate(item.created_at) + ' · ' + change;
        historyList.append(line);
      }
      if (!history.length) historyList.textContent = 'Історія поки порожня.';
      for (const form of content.querySelectorAll('form')) {
        form.onsubmit = async event => {
          event.preventDefault();
          const button = form.querySelector('button[type=submit]');
          const value = new FormData(form).get('text').trim();
          if (!value || button.disabled) return;
          button.disabled = true;
          const step = form.dataset.action === 'step';
          try {
            await take(db.from(step ? 'stage_task_steps' : 'stage_task_comments')
              .insert(step ? { task_id: task.id, title: value } : { task_id: task.id, body: value }));
            await load();
          } catch (error) { fail(error); button.disabled = false; }
        };
      }
    } catch (error) {
      if (content.isConnected) content.textContent = 'Не вдалося завантажити деталі завдання.';
      fail(error);
    }
  }
  load();
}
