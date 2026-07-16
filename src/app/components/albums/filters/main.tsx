import { ListFilter } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useSearchParams } from "react-router-dom";
import { Button } from "@/app/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/app/components/ui/dropdown-menu";
import { AlbumListType } from "@/types/responses/album";
import { setPreferenceValue } from "@/store/native-storage";
import {
  AlbumsFilters,
  AlbumsSearchParams,
  albumsFilterValues,
  PersistedAlbumListKeys,
} from "@/utils/albumsFilter";
import { scrollPageToTop } from "@/utils/scrollPageToTop";
import { SearchParamsHandler } from "@/utils/searchParamsHandler";

const hiddenFilters = [AlbumsFilters.ByDiscography, AlbumsFilters.Search];

export function AlbumsMainFilter() {
  const { t } = useTranslation();
  const [searchParams, setSearchParams] = useSearchParams();
  const { getSearchParam } = new SearchParamsHandler(searchParams);

  const currentFilter = getSearchParam<AlbumListType>(
    AlbumsSearchParams.MainFilter,
    AlbumsFilters.RecentlyAdded,
  );

  const currentFilterLabel = albumsFilterValues.filter(
    (item) => item.key === currentFilter,
  )[0].label;

  function handleChangeFilter(filter: AlbumListType) {
    setPreferenceValue(PersistedAlbumListKeys.MainFilter, filter);

    setSearchParams((state) => {
      const next = new URLSearchParams(state);
      next.set(AlbumsSearchParams.MainFilter, filter);

      next.delete(AlbumsSearchParams.ArtistId);
      next.delete(AlbumsSearchParams.ArtistName);
      if (filter !== AlbumsFilters.ByYear)
        next.delete(AlbumsSearchParams.YearFilter);
      if (filter !== AlbumsFilters.ByGenre)
        next.delete(AlbumsSearchParams.Genre);

      return next;
    });
    scrollPageToTop();
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline" size="sm">
          <ListFilter className="w-4 h-4 mr-2" />
          <span className="hidden sm:block">{t(currentFilterLabel)}</span>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        {albumsFilterValues.map((item, index) => {
          if (hiddenFilters.includes(item.key)) return null;

          return (
            <DropdownMenuCheckboxItem
              key={index}
              checked={item.key === currentFilter}
              onCheckedChange={() =>
                handleChangeFilter(item.key as AlbumListType)
              }
              className="cursor-pointer"
            >
              {t(item.label)}
            </DropdownMenuCheckboxItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
