import { useCallback, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import {
  Content,
  ContentItem,
  ContentItemForm,
  ContentItemTitle,
  ContentSeparator,
  Header,
  HeaderDescription,
  HeaderTitle,
  Root,
} from "@/app/components/settings/section";
import { Button } from "@/app/components/ui/button";
import { ConfirmationDialog } from "@/app/components/ui/confirmation-dialog";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/app/components/ui/select";
import { Switch } from "@/app/components/ui/switch";
import { cacheManager } from "@/service/cache";
import { isNativeCacheAdapterAvailable } from "@/service/cache/native-cache-adapter";
import { isNativeImageCacheAdapterAvailable } from "@/service/cache/native-image-cache-adapter";
import { syncService } from "@/service/cache/sync-worker-adapter";
import {
  useCacheActions,
  useCacheSettings,
  useCacheStore,
  useIsOnline,
  useLastSyncedAt,
  useLibraryCaching,
  useSmartRules,
} from "@/store/cache.store";
import {
  type CachePoolBreakdown,
  useCachePoolStats,
} from "@/store/cache-index.store";
import { clearLibraryData } from "@/store/library-db";
import {
  CACHE_SIZE_OPTIONS,
  type CacheMetaSource,
  COVER_ART_CONCURRENCY_MAX,
  COVER_ART_CONCURRENCY_MIN,
} from "@/types/cache";
import { getRuntime } from "@/utils/capabilities";
import dateTime from "@/utils/dateTime";
import { formatBytes } from "@/utils/formatBytes";
import { CacheManagerSection } from "./cache-manager";

function LibraryCachingSection() {
  const { t } = useTranslation();
  const libraryCaching = useLibraryCaching();
  const isCapacitorNative =
    getRuntime() === "capacitor-ios" || getRuntime() === "capacitor-android";
  const syncCoverArt = useCacheStore((s) => s.settings.syncCoverArt);
  const coverArtConcurrency = useCacheStore(
    (s) => s.settings.coverArtConcurrency,
  );
  const {
    setLibraryCaching,
    setLastSyncedAt,
    setSyncCoverArt,
    setCoverArtConcurrency,
  } = useCacheActions();
  const lastSyncedAt = useLastSyncedAt();
  const isSyncing = useCacheStore((s) => s.status.syncState.isSyncing);
  const isOnline = useIsOnline();
  const [confirmOpen, setConfirmOpen] = useState(false);

  const handleToggle = useCallback(
    (checked: boolean) => {
      if (!checked && lastSyncedAt !== null) {
        setConfirmOpen(true);
        return;
      }
      setLibraryCaching(checked);
    },
    [lastSyncedAt, setLibraryCaching],
  );

  const handleConfirmClear = useCallback(async () => {
    await clearLibraryData();
    setLastSyncedAt(null);
    setLibraryCaching(false);
    setConfirmOpen(false);
  }, [setLastSyncedAt, setLibraryCaching]);

  const handleRefresh = useCallback(() => {
    syncService.syncIncremental({
      includeCoverArt: syncCoverArt,
      includeFullSongs: true,
    });
  }, [syncCoverArt]);

  const handleCancel = useCallback(() => {
    syncService.cancel();
  }, []);

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.storage.offline.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.storage.offline.description")}
        </HeaderDescription>
      </Header>

      <Content>
        <ContentItem>
          <ContentItemTitle
            info={
              isCapacitorNative
                ? t("settings.storage.sync.libraryCachingInfoIos")
                : t("settings.storage.sync.libraryCachingInfo")
            }
          >
            {t("settings.storage.sync.libraryCaching")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch
              checked={libraryCaching}
              onCheckedChange={handleToggle}
              disabled={isCapacitorNative}
            />
          </ContentItemForm>
        </ContentItem>

        <ContentItem>
          <ContentItemTitle info={t("settings.storage.sync.coverArtInfo")}>
            {t("settings.storage.sync.coverArt")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch
              checked={syncCoverArt}
              onCheckedChange={setSyncCoverArt}
              disabled={!libraryCaching}
            />
          </ContentItemForm>
        </ContentItem>

        <ContentItem>
          <ContentItemTitle
            info={t("settings.storage.sync.coverArtConcurrencyInfo")}
          >
            {t("settings.storage.sync.coverArtConcurrency")}
          </ContentItemTitle>
          <ContentItemForm>
            <Select
              value={coverArtConcurrency.toString()}
              onValueChange={(value) =>
                setCoverArtConcurrency(Number.parseInt(value, 10))
              }
              disabled={!libraryCaching || !syncCoverArt}
            >
              <SelectTrigger className="h-8 ring-offset-transparent focus-visible:ring-0 focus-visible:ring-transparent text-left w-[130px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent align="end">
                <SelectGroup>
                  {Array.from(
                    {
                      length:
                        COVER_ART_CONCURRENCY_MAX -
                        COVER_ART_CONCURRENCY_MIN +
                        1,
                    },
                    (_, i) => COVER_ART_CONCURRENCY_MIN + i,
                  ).map((n) => (
                    <SelectItem key={n} value={n.toString()}>
                      {n === 1
                        ? t("settings.storage.sync.coverArtConcurrencyOff")
                        : n}
                    </SelectItem>
                  ))}
                </SelectGroup>
              </SelectContent>
            </Select>
          </ContentItemForm>
        </ContentItem>

        <ContentItem>
          <ContentItemTitle>
            {t("settings.storage.sync.lastSynced")}
          </ContentItemTitle>
          <ContentItemForm className="gap-2">
            <span className="text-xs text-muted-foreground whitespace-nowrap">
              {lastSyncedAt
                ? dateTime(lastSyncedAt).fromNow()
                : t("settings.storage.sync.never")}
            </span>
            {libraryCaching &&
              (isSyncing ? (
                <Button
                  size="sm"
                  variant="outline"
                  className="h-7 text-xs"
                  onClick={handleCancel}
                >
                  {t("settings.storage.sync.cancel")}
                </Button>
              ) : (
                <Button
                  size="sm"
                  variant="outline"
                  className="h-7 text-xs"
                  onClick={handleRefresh}
                  disabled={!isOnline}
                >
                  {t("settings.storage.sync.syncNow")}
                </Button>
              ))}
          </ContentItemForm>
        </ContentItem>
      </Content>

      <ContentSeparator />

      <ConfirmationDialog
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        title={t("settings.storage.sync.clearConfirm.title")}
        description={t("settings.storage.sync.clearConfirm.description")}
        onConfirm={handleConfirmClear}
        cancelLabel={t("settings.storage.sync.clearConfirm.keep")}
        confirmLabel={t("settings.storage.sync.clearConfirm.clear")}
      />
    </Root>
  );
}

function SmartDownloadSection() {
  const { t } = useTranslation();
  const rules = useSmartRules();
  const { setSmartRules } = useCacheActions();

  const setEnabled = (enabled: boolean) => setSmartRules({ enabled });
  const setRule = (key: keyof typeof rules, value: boolean) =>
    setSmartRules({ [key]: value } as Partial<typeof rules>);

  const rows: Array<{
    key: keyof typeof rules;
    labelKey: string;
  }> = [
    {
      key: "favoriteSongs",
      labelKey: "settings.storage.smart.rule.favoriteSongs",
    },
    {
      key: "favoritePlaylists",
      labelKey: "settings.storage.smart.rule.favoritePlaylists",
    },
  ];

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.storage.smart.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.storage.smart.description")}
        </HeaderDescription>
      </Header>

      <Content>
        <ContentItem>
          <ContentItemTitle>
            {t("settings.storage.smart.enabled")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch checked={rules.enabled} onCheckedChange={setEnabled} />
          </ContentItemForm>
        </ContentItem>

        {rows.map(({ key, labelKey }) => (
          <ContentItem key={key}>
            <ContentItemTitle>{t(labelKey)}</ContentItemTitle>
            <ContentItemForm>
              <Switch
                checked={rules.enabled && Boolean(rules[key])}
                disabled={!rules.enabled}
                onCheckedChange={(v) => setRule(key, v)}
              />
            </ContentItemForm>
          </ContentItem>
        ))}
      </Content>

      <ContentSeparator />
    </Root>
  );
}

interface PoolRowProps {
  labelKey: "explicit" | "smart" | "lru" | "assets";
  stats: CachePoolBreakdown;
  quota: number | null;
  onQuotaChange?: (bytes: number) => void;
  onClear: () => void;
  allowEmptyClear?: boolean;
}

function PoolRow({
  labelKey,
  stats,
  quota,
  onQuotaChange,
  onClear,
  allowEmptyClear = false,
}: PoolRowProps) {
  const { t } = useTranslation();
  const sizeLabel = useMemo(() => {
    if (quota === null || quota === 0) {
      return t("settings.storage.limits.unlimited");
    }
    const option = CACHE_SIZE_OPTIONS.find((o) => o.value === quota);
    return option?.label ?? formatBytes(quota);
  }, [quota, t]);

  const entriesLabel =
    labelKey === "assets"
      ? t("settings.storage.limits.imageEntries", { count: stats.count })
      : t("settings.storage.limits.songEntries", { count: stats.count });

  return (
    <ContentItem className="flex-col items-start gap-2 sm:flex-row sm:items-center">
      <div className="flex-1 min-w-0">
        <ContentItemTitle>
          {t(`settings.storage.limits.pool.${labelKey}.label`)}
        </ContentItemTitle>
        <p className="text-xs text-muted-foreground">
          {t(`settings.storage.limits.pool.${labelKey}.description`)}
        </p>
        <p className="text-xs text-muted-foreground mt-1">
          {formatBytes(stats.sizeBytes)} · {entriesLabel}
        </p>
      </div>

      <div className="flex items-center gap-2 shrink-0">
        {onQuotaChange && quota !== null ? (
          <Select
            value={quota.toString()}
            onValueChange={(value) => onQuotaChange(Number(value))}
          >
            <SelectTrigger className="h-8 ring-offset-transparent focus:ring-0 focus:ring-transparent text-left w-[130px]">
              <SelectValue>
                <span className="text-sm text-foreground">{sizeLabel}</span>
              </SelectValue>
            </SelectTrigger>
            <SelectContent align="end">
              <SelectGroup>
                {CACHE_SIZE_OPTIONS.map((option) => (
                  <SelectItem
                    key={option.value}
                    value={option.value.toString()}
                  >
                    {option.label}
                  </SelectItem>
                ))}
              </SelectGroup>
            </SelectContent>
          </Select>
        ) : (
          <span className="text-xs text-muted-foreground">{sizeLabel}</span>
        )}
        <Button
          size="sm"
          variant="outline"
          className="h-7 text-xs"
          onClick={onClear}
          disabled={stats.count === 0 && !allowEmptyClear}
        >
          {t("settings.storage.limits.clearAudio")}
        </Button>
      </div>
    </ContentItem>
  );
}

function CacheLimitsSection() {
  const { t } = useTranslation();
  const { assetsQuota, lruQuota } = useCacheSettings();
  const { setAssetsQuota, setLruQuota } = useCacheActions();
  const stats = useCachePoolStats();
  const hasNativeImageCache = isNativeImageCacheAdapterAvailable();
  const hasNativeCache = hasNativeImageCache || isNativeCacheAdapterAvailable();

  const totalCount =
    stats.explicit.count +
    stats.smart.count +
    stats.lru.count +
    stats.assets.count;

  const clearBySource = useCallback(
    (source: CacheMetaSource) => () => {
      cacheManager.clearAudioBySource(source);
    },
    [],
  );

  const handleClearAssets = useCallback(async () => {
    try {
      await cacheManager.clearAssets();
      toast.success(t("settings.storage.limits.clearAudio"));
    } catch (error) {
      console.error("Failed to clear cover cache", error);
      toast.error(error instanceof Error ? error.message : String(error));
    }
  }, [t]);

  const handleClearAll = useCallback(async () => {
    try {
      await cacheManager.clearAllCaches();
      toast.success(t("settings.storage.limits.clearAll"));
    } catch (error) {
      console.error("Failed to clear all caches", error);
      toast.error(error instanceof Error ? error.message : String(error));
    }
  }, [t]);

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.storage.limits.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.storage.limits.description")}
        </HeaderDescription>
      </Header>

      <Content>
        <PoolRow
          labelKey="explicit"
          stats={stats.explicit}
          quota={null}
          onClear={clearBySource("explicit")}
        />
        <PoolRow
          labelKey="smart"
          stats={stats.smart}
          quota={null}
          onClear={clearBySource("smart")}
        />
        <PoolRow
          labelKey="lru"
          stats={stats.lru}
          quota={lruQuota}
          onQuotaChange={setLruQuota}
          onClear={clearBySource("lru")}
        />
        <PoolRow
          labelKey="assets"
          stats={stats.assets}
          quota={assetsQuota}
          onQuotaChange={setAssetsQuota}
          onClear={handleClearAssets}
          allowEmptyClear={hasNativeImageCache}
        />

        <ContentItem>
          <div className="flex-1" />
          <ContentItemForm>
            <Button
              size="sm"
              variant="destructive"
              className="h-8"
              onClick={handleClearAll}
              disabled={totalCount === 0 && !hasNativeCache}
            >
              {t("settings.storage.limits.clearAll")}
            </Button>
          </ContentItemForm>
        </ContentItem>
      </Content>

      <ContentSeparator />
    </Root>
  );
}

export function Storage() {
  const libraryCaching = useLibraryCaching();

  return (
    <div className="space-y-4">
      <LibraryCachingSection />
      {libraryCaching && <SmartDownloadSection />}
      <CacheLimitsSection />
      <CacheManagerSection />
    </div>
  );
}
