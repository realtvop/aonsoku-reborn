import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Actions } from "@/app/components/actions";
import { OptionsButtons } from "@/app/components/options/buttons";
import {
  DropdownMenuGroup,
  DropdownMenuSeparator,
} from "@/app/components/ui/dropdown-menu";
import { useSongList } from "@/app/hooks/use-song-list";
import { subsonic } from "@/service/subsonic";
import { useAppPages } from "@/store/app.store";
import { usePlayerActions } from "@/store/player.store";
import { IArtist } from "@/types/responses/artist";
import { queryKeys } from "@/utils/queryKeys";
import { ArtistOptions } from "./options";

interface ArtistButtonsProps {
  artist: IArtist;
  showInfoButton: boolean;
  isArtistEmpty: boolean;
}

export function ArtistButtons({
  artist,
  showInfoButton,
  isArtistEmpty,
}: ArtistButtonsProps) {
  const { t } = useTranslation();
  const { setSongList } = usePlayerActions();
  const { showInfoPanel, toggleShowInfoPanel } = useAppPages();
  const { getArtistAllSongs } = useSongList();

  const isArtistStarred = artist.starred !== undefined;
  const [isStarred, setIsStarred] = useState(isArtistStarred);

  useEffect(() => {
    setIsStarred(isArtistStarred);
  }, [isArtistStarred]);

  const queryClient = useQueryClient();

  const starMutation = useMutation({
    mutationFn: subsonic.star.handleStarItem,
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: [...queryKeys.artist.single, artist.id],
      });
      queryClient.invalidateQueries({
        queryKey: queryKeys.favorites.count,
      });
      queryClient.invalidateQueries({
        queryKey: queryKeys.favorites.list,
      });
    },
  });

  function handleLikeButton() {
    if (!artist || starMutation.isPending) return;

    const currentStarred = isStarred;
    setIsStarred(!currentStarred);

    starMutation.mutate(
      {
        id: artist.id,
        starred: currentStarred,
      },
      {
        onError: () => {
          setIsStarred(currentStarred);
        },
      },
    );
  }

  async function handlePlayArtistRadio(shuffle = false) {
    const songList = await getArtistAllSongs(artist?.id || "");

    if (songList) {
      setSongList(
        songList,
        shuffle ? undefined : 0,
        shuffle,
        undefined,
        artist.name,
      );
    }
  }

  const buttonsTooltips = {
    play: t("playlist.buttons.play", { name: artist.name }),
    shuffle: t("playlist.buttons.shuffle", { name: artist.name }),
    options: t("playlist.buttons.options", { name: artist.name }),
    like: () => {
      return isStarred
        ? t("album.buttons.dislike", { name: artist.name })
        : t("album.buttons.like", { name: artist.name });
    },
    info: () => {
      return showInfoPanel
        ? t("generic.hideDetails")
        : t("generic.showDetails");
    },
  };

  if (isArtistEmpty) {
    return <div className="h-8 w-full" />;
  }

  return (
    <Actions.Container>
      <Actions.Button
        tooltip={buttonsTooltips.shuffle}
        onClick={() => handlePlayArtistRadio(true)}
      >
        <Actions.ShuffleIcon />
      </Actions.Button>

      <Actions.Button
        tooltip={buttonsTooltips.play}
        buttonStyle="primary"
        className="md:order-first"
        onClick={() => handlePlayArtistRadio()}
      >
        <Actions.PlayIcon />
      </Actions.Button>

      <Actions.Button
        tooltip={buttonsTooltips.like()}
        className="hidden md:inline-flex"
        disabled={starMutation.isPending}
        onClick={handleLikeButton}
      >
        <Actions.LikeIcon isStarred={isStarred} />
      </Actions.Button>

      {showInfoButton && (
        <Actions.Button
          tooltip={buttonsTooltips.info()}
          className="hidden md:inline-flex"
          onClick={toggleShowInfoPanel}
        >
          <Actions.InfoIcon />
        </Actions.Button>
      )}

      <Actions.Dropdown
        tooltip={buttonsTooltips.options}
        options={
          <>
            <DropdownMenuGroup className="md:hidden">
              <OptionsButtons.Like
                onClick={handleLikeButton}
                isStarred={isStarred}
                label={buttonsTooltips.like()}
                disabled={starMutation.isPending}
              />
            </DropdownMenuGroup>
            <DropdownMenuSeparator className="md:hidden" />
            <ArtistOptions artist={artist} />
          </>
        }
      />
    </Actions.Container>
  );
}
