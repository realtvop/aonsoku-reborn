import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  HeaderFallback,
  PreviewListFallback,
} from "@/app/components/fallbacks/home-fallbacks";
import { MobilePageHeader } from "@/app/components/header/mobile-page-header";
import HomeHeader from "@/app/components/home/carousel/header";
import { CrossDevicePlaybacks } from "@/app/components/home/cross-device-playbacks";
import PinnedList from "@/app/components/home/pinned-list";
import PreviewList from "@/app/components/home/preview-list";
import {
  useGetPinnedHomeItems,
  useGetMostPlayed,
  useGetRandomAlbums,
  useGetCarouselAlbums,
  useGetRecentlyAdded,
  useGetRecentlyPlayed,
} from "@/app/hooks/use-home";
import { PullToRefresh } from "@/app/components/ui/pull-to-refresh";
import { useCacheStore } from "@/store/cache.store";
import { syncService } from "@/service/cache/sync-worker-adapter";
import { getNetworkStatus } from "@/app/hooks/use-network-status";
import { ROUTES } from "@/routes/routesList";

export default function Home() {
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const handleRefresh = async () => {
    const promises = [
      queryClient.invalidateQueries({ queryKey: ["albums"] }),
      queryClient.invalidateQueries({ queryKey: ["home"] }),
    ];

    const state = useCacheStore.getState();
    const network = getNetworkStatus();
    if (
      state.settings.libraryCaching &&
      network.isOnline &&
      !state.status.syncState.isSyncing
    ) {
      syncService.syncIncremental({
        includeCoverArt: state.settings.syncCoverArt,
        includeFullSongs: true,
      });
    }

    await Promise.all(promises);
  };

  const {
    data: carouselAlbums,
    isLoading,
    isFetching,
  } = useGetCarouselAlbums();
  const pinnedItems = useGetPinnedHomeItems();

  const recentlyPlayed = useGetRecentlyPlayed();
  const mostPlayed = useGetMostPlayed();
  const recentlyAdded = useGetRecentlyAdded();
  const randomAlbums = useGetRandomAlbums();

  const sections = [
    {
      title: t("home.recentlyPlayed"),
      data: recentlyPlayed.data,
      loader: recentlyPlayed.isLoading,
      route: ROUTES.ALBUMS.RECENTLY_PLAYED,
    },
    {
      title: t("home.mostPlayed"),
      data: mostPlayed.data,
      loader: mostPlayed.isLoading,
      route: ROUTES.ALBUMS.MOST_PLAYED,
    },
    {
      title: t("home.recentlyAdded"),
      data: recentlyAdded.data,
      loader: recentlyAdded.isLoading,
      route: ROUTES.ALBUMS.RECENTLY_ADDED,
    },
    {
      title: t("home.explore"),
      data: randomAlbums.data,
      loader: randomAlbums.isLoading,
      route: ROUTES.ALBUMS.RANDOM,
    },
  ];

  return (
    <PullToRefresh onRefresh={handleRefresh}>
      <div className="w-full px-4 sm:px-8 py-4 sm:py-6">
        <MobilePageHeader
          variant="root"
          title={t("sidebar.home")}
          showUserDropdown
        />

        <CrossDevicePlaybacks />

        {isFetching || isLoading ? (
          <HeaderFallback />
        ) : (
          <HomeHeader albums={carouselAlbums?.list || []} />
        )}

        {pinnedItems.isLoading && <PreviewListFallback />}
        {!!pinnedItems.data?.length && (
          <PinnedList list={pinnedItems.data} title={t("home.pinned")} />
        )}

        {sections.map((section) => {
          if (section.loader) {
            return <PreviewListFallback key={section.title} />;
          }

          if (!section.data?.list?.length) return null;

          return (
            <PreviewList
              key={section.title}
              title={section.title}
              moreRoute={section.route}
              list={section.data.list}
            />
          );
        })}
      </div>
    </PullToRefresh>
  );
}
