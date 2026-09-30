/**
 * assets/updater.js — Клиентский модуль проверки и применения обновлений с GitHub
 * Проект: astradriverslinux (biblioteka33.ru/linux)
 */

(function () {
  const GITHUB_REPO = 'giddammit-crypto/astradriverslinux';
  const GITHUB_BRANCH = 'main';
  const API_ENDPOINT = 'api/updater.php';

  let updaterState = {
    currentVersion: '2.1.0',
    currentCommit: '',
    remoteCommit: '',
    hasUpdate: false,
    checking: false
  };

  async function checkUpdates() {
    const badge = document.getElementById('updater-badge');
    const updateBtn = document.getElementById('btn-check-updates');
    if (updateBtn) {
      updateBtn.disabled = true;
      updateBtn.innerText = 'Проверка...';
    }

    try {
      // 1. Попытка через бэкенд api/updater.php
      let res = await fetch(`${API_ENDPOINT}?action=check`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'check' })
      }).catch(() => null);

      if (res && res.ok) {
        const data = await res.json();
        handleUpdateResult(data);
        return;
      }

      // 2. Фолбэк напрямую через открытый GitHub API
      const ghRes = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/commits/${GITHUB_BRANCH}`, {
        headers: { 'Accept': 'application/vnd.github.v3+json' }
      });
      if (ghRes.ok) {
        const commit = await ghRes.json();
        const shortSha = commit.sha.substring(0, 7);
        const msg = commit.commit.message.split('\n')[0];
        handleUpdateResult({
          ok: true,
          has_update: true,
          latest_commit: {
            sha: commit.sha,
            short_sha: shortSha,
            message: msg,
            date: commit.commit.committer.date
          }
        });
      }
    } catch (e) {
      console.warn('Updater check error:', e);
      if (badge) {
        badge.innerHTML = `<span style="color:#ef4444">Ошибка проверки</span>`;
      }
    } finally {
      if (updateBtn) {
        updateBtn.disabled = false;
        updateBtn.innerText = 'Проверить';
      }
    }
  }

  function handleUpdateResult(data) {
    const badge = document.getElementById('updater-badge');
    const updateBanner = document.getElementById('update-notification-banner');
    if (!data || !data.ok) return;

    if (data.latest_commit) {
      updaterState.remoteCommit = data.latest_commit.short_sha;
    }

    if (badge) {
      badge.innerHTML = `
        <span class="status-dot"></span>
        <span>GitHub: <a href="https://github.com/${GITHUB_REPO}" target="_blank" rel="noopener" style="color:inherit;text-decoration:underline">${updaterState.remoteCommit || 'online'}</a></span>
      `;
    }

    if (data.has_update && updateBanner) {
      updateBanner.style.display = 'block';
      const msgElem = document.getElementById('update-banner-msg');
      if (msgElem && data.latest_commit) {
        msgElem.innerHTML = `
          <strong>Доступно свежее обновление (${data.latest_commit.short_sha}):</strong>
          <em>«${data.latest_commit.message}»</em>
        `;
      }
    }
  }

  async function applyServerUpdate() {
    const applyBtn = document.getElementById('btn-apply-update');
    if (applyBtn) {
      applyBtn.disabled = true;
      applyBtn.innerText = 'Обновление...';
    }

    try {
      const res = await fetch(API_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'update' })
      });
      const data = await res.json();
      if (data && data.ok) {
        alert('Обновление успешно установлено! Страница будет перезагружена.');
        window.location.reload();
      } else {
        alert('Ошибка обновления: ' + (data.error || 'Проверьте права доступа на сервере'));
      }
    } catch (e) {
      alert('Ошибка соединения с сервером обновлений: ' + e.message);
    } finally {
      if (applyBtn) {
        applyBtn.disabled = false;
        applyBtn.innerText = 'Обновить сайт и скрипты';
      }
    }
  }

  window.CosmoUpdater = {
    check: checkUpdates,
    apply: applyServerUpdate
  };

  document.addEventListener('DOMContentLoaded', () => {
    const checkBtn = document.getElementById('btn-check-updates');
    if (checkBtn) {
      checkBtn.addEventListener('click', (e) => {
        e.preventDefault();
        checkUpdates();
      });
    }
    const applyBtn = document.getElementById('btn-apply-update');
    if (applyBtn) {
      applyBtn.addEventListener('click', (e) => {
        e.preventDefault();
        applyServerUpdate();
      });
    }

    // Фоновая проверка при открытии страницы
    setTimeout(checkUpdates, 1500);
  });
})();
