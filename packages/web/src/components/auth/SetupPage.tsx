import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { PASSWORD_MIN_LENGTH } from '@patogh/shared/src/constants';
import { useAuthStore } from '../../stores/authStore';
import { invalidateHomeInstanceInfo } from '../../hooks/useHomeInstanceInfo';
import { describeError } from '../../i18n/errors';

/**
 * First-run setup on a fresh instance: names the server and creates the
 * owner's account. Shown instead of login/register until an owner exists.
 */
export function SetupPage() {
  const { t } = useTranslation(['auth', 'common']);
  const [serverName, setServerName] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [error, setError] = useState('');
  const register = useAuthStore((s) => s.register);
  const isLoading = useAuthStore((s) => s.isLoading);
  const navigate = useNavigate();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (!serverName.trim()) {
      setError(t('auth:setup.serverNameRequired'));
      return;
    }
    if (!username.trim()) {
      setError(t('auth:validation.usernameRequired'));
      return;
    }
    if (password.length < PASSWORD_MIN_LENGTH) {
      setError(t('auth:validation.passwordMinLength', { min: PASSWORD_MIN_LENGTH }));
      return;
    }
    if (password !== confirmPassword) {
      setError(t('auth:validation.passwordMismatch'));
      return;
    }

    try {
      await register(username.trim().toLowerCase(), password, undefined, undefined, serverName.trim());
      invalidateHomeInstanceInfo();
      navigate('/channels/@me');
    } catch (err) {
      setError(err instanceof Error ? describeError(err) : t('auth:setup.failed'));
    }
  };

  const field = (label: string, input: React.ReactNode, hint?: string) => (
    <div className="mb-5">
      <label className="block text-xs font-bold text-txt-secondary uppercase mb-2">
        {label} <span className="text-txt-danger">*</span>
      </label>
      {input}
      {hint && <p className="text-xs text-txt-tertiary mt-1.5">{hint}</p>}
    </div>
  );

  return (
    <div className="h-full overflow-y-auto flex flex-col items-center bg-surface-base relative">
      <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top,rgb(var(--accent-primary)/0.06)_0%,transparent_50%)]" />
      <div className="my-auto flex-shrink-0 w-full max-w-[480px] bg-surface-elevated rounded-md p-8 shadow-elevation-high relative z-10">
        <div className="text-center mb-6">
          <h1 className="text-2xl font-bold text-txt-primary">{t('auth:setup.title')}</h1>
          <p className="text-txt-tertiary mt-1">{t('auth:setup.subtitle')}</p>
        </div>

        <form onSubmit={handleSubmit}>
          {error && (
            <div className="mb-4 p-3 bg-accent-rose/10 border border-accent-rose/30 rounded text-txt-danger text-sm">
              {error}
            </div>
          )}

          {field(t('auth:setup.serverName'), (
            <input
              type="text"
              value={serverName}
              onChange={(e) => setServerName(e.target.value)}
              maxLength={32}
              className="input-standard w-full py-2.5"
              autoFocus
            />
          ))}

          <div className="border-t border-white/[0.05] my-6" />
          <p className="text-sm font-medium text-txt-secondary mb-4">{t('auth:setup.ownerHeading')}</p>

          {field(t('common:labels.username'), (
            <input
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="input-standard w-full py-2.5"
              autoComplete="username"
            />
          ), t('auth:validation.usernameCharset'))}

          {field(t('common:labels.password'), (
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="input-standard w-full py-2.5"
              autoComplete="new-password"
            />
          ))}

          {field(t('auth:fields.confirmPassword'), (
            <input
              type="password"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              className="input-standard w-full py-2.5"
              autoComplete="new-password"
            />
          ))}

          <button
            type="submit"
            disabled={isLoading}
            className="w-full py-2.5 bg-accent-primary hover:bg-accent-primary/80 text-white font-medium rounded transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isLoading ? t('auth:setup.submitting') : t('auth:setup.submit')}
          </button>
        </form>
      </div>
    </div>
  );
}
