import { useState, useEffect, useCallback, useMemo } from 'react';
import { useHomeInstanceInfo } from '../../../hooks/useHomeInstanceInfo';
import { useTranslation } from 'react-i18next';
import { useSettingsStore } from '../../../stores/settingsStore';
import { useSettingsSections } from '../../../hooks/useSettingsSections';
import { useInstanceUpdateBadge } from '../../../hooks/useInstanceUpdateBadge';
import type { SettingsSection } from '../SettingsSectionsContext';
import { SettingsTabBar } from '../SettingsTabBar';
import { GeneralPanel } from '../instanceSettingsPanels/GeneralPanel';
import { RegistrationPanel } from '../instanceSettingsPanels/RegistrationPanel';
import { FederationPanel } from '../instanceSettingsPanels/FederationPanel';
import { StreamingPanel } from '../instanceSettingsPanels/StreamingPanel';
import { StoragePanel } from '../instanceSettingsPanels/StoragePanel';
import { UsersPanel } from '../instanceSettingsPanels/UsersPanel';
import { UpdatesPanel } from '../instanceSettingsPanels/UpdatesPanel';

type SubTab = 'general' | 'registration' | 'federation' | 'streaming' | 'storage' | 'users' | 'updates';

export function InstancePanel() {
  const { t } = useTranslation(['settings']);
  const fetchInstanceSettings = useSettingsStore((s) => s.fetchInstanceSettings);

  const [subTab, setSubTab] = useState<SubTab>('general');
  const [approvalCount, setApprovalCount] = useState(0);
  const federationEnabled = useHomeInstanceInfo()?.federationEnabled ?? false;
  const updateBadge = useInstanceUpdateBadge();

  const sections = useMemo<SettingsSection[]>(() => [
    { id: 'general', label: t('settings:instance.tabs.general') },
    { id: 'registration', label: t('settings:instance.tabs.registration') },
    ...(federationEnabled ? [{ id: 'federation', label: t('settings:instance.tabs.federation'), badgeCount: approvalCount }] : []),
    { id: 'streaming', label: t('settings:instance.tabs.streaming') },
    { id: 'storage', label: t('settings:instance.tabs.storage') },
    { id: 'users', label: t('settings:instance.tabs.users') },
    { id: 'updates', label: t('settings:instance.tabs.updates'), badgeDot: updateBadge },
  ], [approvalCount, updateBadge, t, federationEnabled]);

  const handleNavigate = useCallback((id: string) => {
    setSubTab(id as SubTab);
  }, []);

  // Register sections for sidebar sub-links (tab mode — no scroll-spy)
  useSettingsSections(sections, { onNavigate: handleNavigate, activeTab: subTab });

  useEffect(() => {
    fetchInstanceSettings();
    // The streaming limits are not fetched here: `StreamingPanel` is the only
    // reader of that document in this tree and loads it itself, which is also
    // how it can say when the load failed.
  }, [fetchInstanceSettings]);

  return (
    <div className="space-y-4">
      <SettingsTabBar />

      {subTab === 'general' && <GeneralPanel />}
      {subTab === 'registration' && <RegistrationPanel />}
      {subTab === 'federation' && <FederationPanel onApprovalCountChange={setApprovalCount} />}
      {subTab === 'streaming' && <StreamingPanel />}
      {subTab === 'storage' && <StoragePanel />}
      {subTab === 'users' && <UsersPanel />}
      {subTab === 'updates' && <UpdatesPanel />}
    </div>
  );
}
