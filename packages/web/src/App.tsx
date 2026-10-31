import React, { useEffect } from 'react';
import { Routes, Route, Navigate, useSearchParams } from 'react-router-dom';
import { LoginPage } from './components/auth/LoginPage';
import { RegisterPage } from './components/auth/RegisterPage';
import { SetupPage } from './components/auth/SetupPage';
import { useHomeInstanceInfo } from './hooks/useHomeInstanceInfo';
import { AppLayout } from './components/layout/AppLayout';
import { JoinPage } from './components/JoinPage';
import { SwAutoUpdate } from './components/ui/SwUpdatePrompt';
import { ScreenShareSetup } from './components/voice/ScreenShareSetup';
import { useAuthStore } from './stores/authStore';
import { isElectron } from './platform/platform';

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const token = useAuthStore((s) => s.token);
  // i18n-check: allow-literal — the `; return` between the two elements is code, not text.
  if (!token) return <Navigate to="/login" replace />;
  return <>{children}</>;
}

function AuthRedirect({ children }: { children: React.ReactNode }) {
  const token = useAuthStore((s) => s.token);
  const [searchParams] = useSearchParams();
  const redirect = searchParams.get('redirect');
  if (token) {
    if (redirect && redirect.startsWith('/') && !redirect.startsWith('//')) {
      return <Navigate to={redirect} replace />;
    }
    return <Navigate to="/channels/@me" replace />;
  }
  return <>{children}</>;
}

/**
 * A fresh instance has no owner: first-run setup replaces login and register
 * until it does, and setup is closed once it has one. While the info is still
 * loading, the requested page renders as is.
 */
function SetupGate({ setup = false, children }: { setup?: boolean; children: React.ReactNode }) {
  const setupRequired = useHomeInstanceInfo()?.setupRequired;
  if (setupRequired === !setup) return <Navigate to={setup ? '/login' : '/setup'} replace />;
  return <>{children}</>;
}

export function App() {
  // Boot-completion ping — disarms the main-process boot timer.
  // MUST be first hook on the unconditional render path. Single fire on
  // first commit; main owns "armed once" gating so duplicate calls (e.g.
  // ErrorBoundary path) are idempotent. Semantic: "renderer survived
  // render," NOT "data loaded." A spinner on screen counts as boot success.
  //
  // Gated on VITE_FORCE_BOOT_STALL so the smoke-test harness can build a
  // variant that intentionally never pings, exercising the renderer-stalled
  // recovery path without hand-editing source. Set 'true' / '1' to force stall.
  useEffect(() => {
    if (import.meta.env.VITE_FORCE_BOOT_STALL) return;
    if (typeof window.patogh?.rendererReady === 'function') {
      window.patogh.rendererReady();
    }
  }, []);

  const showTitleBar = isElectron();

  return (
    <div className={`flex flex-col ${showTitleBar ? 'h-screen' : 'contents'}`}>
      {showTitleBar && (
        <div className="flex-shrink-0 bg-surface-base border-b border-border-hard titlebar-drag"
          style={{ height: 'var(--titlebar-inset)', borderBottomWidth: 'calc(1px / var(--interface-scale))' }} />
      )}
      <div className={showTitleBar ? 'flex-1 min-h-0' : 'contents'}>
        <SwAutoUpdate />
        <ScreenShareSetup />
        <Routes>
          <Route
            path="/login"
            element={
              <AuthRedirect>
                <SetupGate>
                  <LoginPage />
                </SetupGate>
              </AuthRedirect>
            }
          />
          <Route
            path="/setup"
            element={
              <AuthRedirect>
                <SetupGate setup>
                  <SetupPage />
                </SetupGate>
              </AuthRedirect>
            }
          />
          <Route
            path="/register"
            element={
              <AuthRedirect>
                <SetupGate>
                  <RegisterPage />
                </SetupGate>
              </AuthRedirect>
            }
          />
          <Route
            path="/channels/:spaceId/:channelId?"
            element={
              <ProtectedRoute>
                <AppLayout />
              </ProtectedRoute>
            }
          />
          <Route
            path="/join/:inviteCode"
            element={<JoinPage />}
          />
          <Route
            path="/explore"
            element={
              <ProtectedRoute>
                <AppLayout />
              </ProtectedRoute>
            }
          />
          <Route path="/" element={<Navigate to="/channels/@me" replace />} />
          <Route path="*" element={<Navigate to="/channels/@me" replace />} />
        </Routes>
      </div>
    </div>
  );
}
