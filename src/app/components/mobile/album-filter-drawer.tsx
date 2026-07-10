import { CheckIcon } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useSearchParams } from "react-router-dom";
import {
  Drawer,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
} from "@/app/components/ui/drawer";
import { AlbumListType } from "@/types/responses/album";
import { setPreferenceValue } from "@/store/native-storage";
import {
  AlbumsFilters,
  AlbumsSearchParams,
  PersistedAlbumListKeys,
  YearSortOptions,
  albumsFilterValues,
} from "@/utils/albumsFilter";
import { SearchParamsHandler } from "@/utils/searchParamsHandler";

interface MobileAlbumFilterDrawerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const hiddenFilters: string[] = [
  AlbumsFilters.ByDiscography,
  AlbumsFilters.Search,
  AlbumsFilters.ByGenre,
];

const yearOptions = [
  { label: "album.list.filter.year.oldest", value: YearSortOptions.Oldest },
  { label: "album.list.filter.year.newest", value: YearSortOptions.Newest },
];

export function MobileAlbumFilterDrawer({
  open,
  onOpenChange,
}: MobileAlbumFilterDrawerProps) {
  const { t } = useTranslation();
  const [searchParams, setSearchParams] = useSearchParams();
  const { getSearchParam } = new SearchParamsHandler(searchParams);

  const currentFilter = getSearchParam<AlbumListType>(
    AlbumsSearchParams.MainFilter,
    AlbumsFilters.RecentlyAdded,
  );
  const currentYearFilter = getSearchParam<string>(
    AlbumsSearchParams.YearFilter,
    YearSortOptions.Oldest,
  );

  function handleChangeFilter(filter: AlbumListType) {
    setPreferenceValue(PersistedAlbumListKeys.MainFilter, filter);

    setSearchParams(
      (state) => {
        const next = new URLSearchParams(state);
        next.set(AlbumsSearchParams.MainFilter, filter);
        next.delete(AlbumsSearchParams.ArtistId);
        next.delete(AlbumsSearchParams.ArtistName);
        if (filter !== AlbumsFilters.ByYear)
          next.delete(AlbumsSearchParams.YearFilter);
        return next;
      },
      { replace: true },
    );

    if (filter !== AlbumsFilters.ByYear) {
      onOpenChange(false);
    }
  }

  function handleChangeYearFilter(value: string) {
    setPreferenceValue(PersistedAlbumListKeys.YearFilter, value);

    setSearchParams(
      (state) => {
        const next = new URLSearchParams(state);
        next.set(AlbumsSearchParams.YearFilter, value);
        return next;
      },
      { replace: true },
    );
    onOpenChange(false);
  }

  const visibleFilters = albumsFilterValues.filter(
    (item) => !hiddenFilters.includes(item.key),
  );

  return (
    <Drawer open={open} onOpenChange={onOpenChange}>
      <DrawerContent>
        <DrawerHeader>
          <DrawerTitle>{t("album.list.filter.label")}</DrawerTitle>
        </DrawerHeader>
        <div className="px-4 pb-6 space-y-4">
          <div className="space-y-1">
            {visibleFilters.map(({ key, label }) => (
              <button
                key={key}
                type="button"
                className="flex w-full items-center justify-between rounded-md px-3 py-2.5 text-sm active:bg-accent/50"
                onClick={() => handleChangeFilter(key as AlbumListType)}
              >
                <span>{t(label)}</span>
                {currentFilter === key && (
                  <CheckIcon className="size-4 text-primary" />
                )}
              </button>
            ))}
          </div>
          {currentFilter === AlbumsFilters.ByYear && (
            <>
              <div className="h-px bg-border" />
              <div className="space-y-1">
                {yearOptions.map(({ label, value }) => (
                  <button
                    key={value}
                    type="button"
                    className="flex w-full items-center justify-between rounded-md px-3 py-2.5 text-sm active:bg-accent/50"
                    onClick={() => handleChangeYearFilter(value)}
                  >
                    <span>{t(label)}</span>
                    {currentYearFilter === value && (
                      <CheckIcon className="size-4 text-primary" />
                    )}
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      </DrawerContent>
    </Drawer>
  );
}
