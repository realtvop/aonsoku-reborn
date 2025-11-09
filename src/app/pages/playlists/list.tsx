import { useQuery } from "@tanstack/react-query";
import clsx from "clsx";
import { PlusIcon } from "lucide-react";
import { useTranslation } from "react-i18next";

import { ShadowHeader } from "@/app/components/album/shadow-header";
import { SongListFallback } from "@/app/components/fallbacks/song-fallbacks";
import { HeaderTitle } from "@/app/components/header-title";
import { EmptyPlaylistsPage } from "@/app/components/playlist/empty-page";
import { Button } from "@/app/components/ui/button";
import { DataTableList } from "@/app/components/ui/data-table-list";
import { playlistsColumns } from "@/app/tables/playlists-columns";
import { subsonic } from "@/service/subsonic";
import { usePlaylists } from "@/store/playlists.store";
import { queryKeys } from "@/utils/queryKeys";
import { useNavigate } from "react-router-dom";
import { ROUTES } from "@/routes/routesList";

export default function PlaylistsPage() {
  const { setPlaylistDialogState } = usePlaylists();
  const { t } = useTranslation();

  const { data: playlists, isLoading } = useQuery({
    queryKey: [queryKeys.playlist.all],
    queryFn: subsonic.playlists.getAll,
  });

  const columns = playlistsColumns();
  const navigate = useNavigate();

  if (isLoading) return <SongListFallback />;
  if (!playlists) return null;

  const showTable = playlists.length > 0;

  return (
    <div className={clsx("w-full", showTable ? "h-content" : "h-content")}>
      <ShadowHeader
        showGlassEffect={false}
        fixed={false}
        className="relative w-full justify-between items-center"
      >
        <div className="w-full flex items-center justify-between">
          <HeaderTitle
            title={t("sidebar.playlists")}
            count={playlists.length}
          />
        </div>

        <Button
          size="sm"
          variant="default"
          className="px-4"
          onClick={() => setPlaylistDialogState(true)}
        >
          <PlusIcon className="w-5 h-5 -ml-[3px]" />
          <span className="ml-2">{t("playlist.form.create.title")}</span>
        </Button>
      </ShadowHeader>

      {!showTable && <EmptyPlaylistsPage />}

      {showTable && (
        <div className="w-full h-[calc(100%-80px)]">
          <DataTableList
            columns={columns}
            data={playlists}
            handlePlaySong={(row) =>
              navigate(ROUTES.PLAYLIST.PAGE(row.original.id))
            }
            allowRowSelection={false}
            dataType="playlist"
          />
        </div>
      )}
    </div>
  );
}
