import { useTranslation } from "react-i18next";
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
import { Switch } from "@/app/components/ui/switch";
import {
  useCoverArtSettings,
  useFullscreenPlayerSettings,
} from "@/store/player.store";
import { useTheme } from "@/store/theme.store";

export function FullscreenSettings() {
  const { t } = useTranslation();
  const { autoFullscreenEnabled, setAutoFullscreenEnabled } =
    useFullscreenPlayerSettings();
  const { useAlbumCoverForSongs, setUseAlbumCoverForSongs } =
    useCoverArtSettings();
  const { usePointerCursors, setUsePointerCursors } = useTheme();

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.appearance.general.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.appearance.general.description")}
        </HeaderDescription>
      </Header>
      <Content>
        <ContentItem>
          <ContentItemTitle
            info={t("settings.appearance.general.fullscreen.info")}
          >
            {t("settings.appearance.general.fullscreen.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch
              checked={autoFullscreenEnabled}
              onCheckedChange={setAutoFullscreenEnabled}
            />
          </ContentItemForm>
        </ContentItem>
        <ContentItem>
          <ContentItemTitle
            info={t("settings.appearance.general.albumCoverForSongs.info")}
          >
            {t("settings.appearance.general.albumCoverForSongs.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch
              checked={useAlbumCoverForSongs}
              onCheckedChange={setUseAlbumCoverForSongs}
            />
          </ContentItemForm>
        </ContentItem>
        <ContentItem>
          <ContentItemTitle
            info={t("settings.appearance.general.usePointerCursors.info")}
          >
            {t("settings.appearance.general.usePointerCursors.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch
              checked={usePointerCursors}
              onCheckedChange={setUsePointerCursors}
            />
          </ContentItemForm>
        </ContentItem>
      </Content>
      <ContentSeparator />
    </Root>
  );
}
