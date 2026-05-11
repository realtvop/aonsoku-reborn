import { zodResolver } from "@hookform/resolvers/zod";
import { useQueryClient } from "@tanstack/react-query";
import clsx from "clsx";
import { ArrowLeft, Loader2 } from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";

import { toast } from "react-toastify";
import { z } from "zod";
import { fetchSubsonicInfo } from "@/api/coordinationApi";
import { queryServerInfo } from "@/api/queryServerInfo";
import { LangToggle } from "@/app/components/login/lang-toggle";
import { Badge } from "@/app/components/ui/badge";
import { Button } from "@/app/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/app/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/app/components/ui/dialog";
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/app/components/ui/form";
import { Input } from "@/app/components/ui/input";
import { Password } from "@/app/components/ui/password";
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/app/components/ui/tabs";
import { ROUTES } from "@/routes/routesList";
import { useAppActions, useAppData } from "@/store/app.store";
import type { ConnectionMode } from "@/types/serverConfig";
import { isDesktop } from "@/utils/desktop";
import { removeSlashFromUrl } from "@/utils/removeSlashFromUrl";

type CoordinationStep = "url" | "credentials";

const directSchema = z.object({
  url: z
    .string()
    .url({ message: "login.form.validations.url" })
    .refine((value) => /^https?:\/\//.test(value), {
      message: "login.form.validations.protocol",
    }),
  username: z
    .string({ required_error: "login.form.validations.username" })
    .min(2, { message: "login.form.validations.usernameLength" }),
  password: z
    .string({ required_error: "login.form.validations.password" })
    .min(2, { message: "login.form.validations.passwordLength" }),
});

const coordinationUrlSchema = z.object({
  coordinationUrl: z
    .string()
    .url({ message: "login.form.validations.url" })
    .refine((value) => /^https?:\/\//.test(value), {
      message: "login.form.validations.protocol",
    }),
});

const coordinationCredentialsSchema = z.object({
  username: z
    .string({ required_error: "login.form.validations.username" })
    .min(2, { message: "login.form.validations.usernameLength" }),
  password: z
    .string({ required_error: "login.form.validations.password" })
    .min(2, { message: "login.form.validations.passwordLength" }),
});

type DirectFormData = z.infer<typeof directSchema>;
type CoordinationUrlData = z.infer<typeof coordinationUrlSchema>;
type CoordinationCredentialsData = z.infer<
  typeof coordinationCredentialsSchema
>;

const defaultUrl = isDesktop() ? "http://" : "https://";
const url = window.SERVER_URL || defaultUrl;
const urlIsValid = url !== defaultUrl;

export function LoginForm() {
  const [loading, setLoading] = useState(false);
  const [serverIsIncompatible, setServerIsIncompatible] = useState(false);
  const [connectionMode, setConnectionMode] = useState<ConnectionMode>("direct");
  const [coordinationStep, setCoordinationStep] = useState<CoordinationStep>(
    "url",
  );

  const [subsonicInfo, setSubsonicInfo] = useState<{
    url: string;
    reverseProxyEnabled: boolean;
  } | null>(null);
  const [fetchingInfo, setFetchingInfo] = useState(false);

  const { saveConfig } = useAppActions();
  const { hideServer } = useAppData();
  const navigate = useNavigate();
  const { t } = useTranslation();
  const queryClient = useQueryClient();

  const shouldHideUrlInput = urlIsValid && hideServer;

  const directForm = useForm<DirectFormData>({
    resolver: zodResolver(directSchema),
    values: {
      url,
      username: "",
      password: "",
    },
  });

  const coordinationUrlForm = useForm<CoordinationUrlData>({
    resolver: zodResolver(coordinationUrlSchema),
    defaultValues: {
      coordinationUrl: "https://",
    },
  });

  const coordinationCredentialsForm = useForm<CoordinationCredentialsData>({
    resolver: zodResolver(coordinationCredentialsSchema),
    defaultValues: {
      username: "",
      password: "",
    },
  });

  async function handleSuccess() {
    await queryClient.invalidateQueries({ queryKey: ["albums"] });
    await queryClient.invalidateQueries({ queryKey: ["artists"] });
    await queryClient.invalidateQueries({ queryKey: ["songs"] });
    await queryClient.invalidateQueries({ queryKey: ["playlists"] });
    await queryClient.invalidateQueries({ queryKey: ["favorites"] });
    await queryClient.invalidateQueries({ queryKey: ["genres"] });
    await queryClient.invalidateQueries({ queryKey: ["radios"] });
    await queryClient.invalidateQueries({ queryKey: ["search"] });
    toast.success(t("toast.server.success"));
    navigate(ROUTES.LIBRARY.HOME, { replace: true });
  }

  async function onSubmitCoordinationUrl(data: CoordinationUrlData) {
    const trimmed = removeSlashFromUrl(data.coordinationUrl);

    setFetchingInfo(true);
    try {
      const info = await fetchSubsonicInfo(trimmed);
      setSubsonicInfo(info);
      setCoordinationStep("credentials");
    } catch {
      setSubsonicInfo(null);
      toast.error(t("login.form.coordinationFetchError"));
    } finally {
      setFetchingInfo(false);
    }
  }

  async function onSubmitDirect(
    data: DirectFormData,
    forceCompatible?: boolean,
  ) {
    setLoading(true);

    const serverInfo = await queryServerInfo(removeSlashFromUrl(data.url));

    if (serverInfo.protocolVersionNumber < 1150 && forceCompatible !== true) {
      setServerIsIncompatible(true);
      setLoading(false);
      return;
    }

    setServerIsIncompatible(false);

    const status = await saveConfig({
      ...data,
      url: removeSlashFromUrl(data.url),
      connectionMode: "direct",
    });

    if (status) {
      await handleSuccess();
    } else {
      setLoading(false);
      toast.error(t("toast.server.error"));
    }
  }

  async function onSubmitCoordinationCredentials(
    data: CoordinationCredentialsData,
  ) {
    if (!subsonicInfo) return;

    setLoading(true);

    const coordinationUrl = removeSlashFromUrl(
      coordinationUrlForm.getValues("coordinationUrl"),
    );
    const proxyUrl = `${coordinationUrl}/subsonic`;
    const fallbackUrl = subsonicInfo.url;

    const status = await saveConfig({
      url: proxyUrl,
      fallbackUrl,
      username: data.username,
      password: data.password,
      connectionMode: "coordination",
      coordinationUrl,
    });

    if (status) {
      await handleSuccess();
    } else {
      setLoading(false);
      toast.error(t("toast.server.error"));
    }
  }

  function handleSwitchMode(mode: ConnectionMode) {
    setConnectionMode(mode);
    setSubsonicInfo(null);
    setCoordinationStep("url");
  }

  return (
    <>
      <Card className="max-w-[80vw] w-[450px] bg-background-foreground">
        <Tabs
          value={connectionMode}
          onValueChange={(v) => handleSwitchMode(v as ConnectionMode)}
        >
          <CardHeader className="flex">
            <CardTitle className="flex flex-row justify-between items-center">
              {t("login.form.server")}
              <div className="flex gap-2 items-center">
                <LangToggle />
              </div>
            </CardTitle>
            <CardDescription>{t("login.form.description")}</CardDescription>
            <TabsList className="w-full mt-2">
              <TabsTrigger value="direct" className="flex-1">
                {t("login.form.direct")}
              </TabsTrigger>
              <TabsTrigger value="coordination" className="flex-1">
                {t("login.form.coordinationServer")}
              </TabsTrigger>
            </TabsList>
          </CardHeader>

          <CardContent className="space-y-2">
            <TabsContent value="direct">
              <Form {...directForm}>
                <form
                  id="direct-form"
                  onSubmit={directForm.handleSubmit((data) =>
                    onSubmitDirect(data),
                  )}
                  className="space-y-2"
                >
                  <FormField
                    control={directForm.control}
                    name="url"
                    render={({ field }) => (
                      <FormItem
                        className={clsx(shouldHideUrlInput && "hidden")}
                      >
                        <FormLabel className="required">
                          {t("login.form.url")}
                        </FormLabel>
                        <FormControl>
                          <Input
                            {...field}
                            id="url"
                            type="text"
                            placeholder={t("login.form.urlDescription")}
                            autoCorrect="false"
                            autoCapitalize="false"
                            spellCheck="false"
                          />
                        </FormControl>
                        <FormDescription>
                          {t("login.form.urlDescription")}
                        </FormDescription>
                        <FormMessage />
                      </FormItem>
                    )}
                  />

                  <FormField
                    control={directForm.control}
                    name="username"
                    render={({ field }) => (
                      <FormItem
                        className={clsx(shouldHideUrlInput && "!mt-0")}
                      >
                        <FormLabel className="required">
                          {t("login.form.username")}
                        </FormLabel>
                        <FormControl>
                          <Input
                            {...field}
                            value={field.value ?? ""}
                            id="direct-username"
                            type="text"
                            placeholder={t("login.form.usernamePlaceholder")}
                            autoCorrect="false"
                            autoCapitalize="false"
                            spellCheck="false"
                          />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />

                  <FormField
                    control={directForm.control}
                    name="password"
                    render={({ field }) => (
                      <FormItem>
                        <FormLabel className="required">
                          {t("login.form.password")}
                        </FormLabel>
                        <FormControl>
                          <Password {...field} value={field.value ?? ""} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </form>
              </Form>
            </TabsContent>

            <TabsContent value="coordination">
              {coordinationStep === "url" && (
                <Form {...coordinationUrlForm}>
                  <form
                    id="coordination-url-form"
                    onSubmit={coordinationUrlForm.handleSubmit(
                      onSubmitCoordinationUrl,
                    )}
                    className="space-y-2"
                  >
                    <FormField
                      control={coordinationUrlForm.control}
                      name="coordinationUrl"
                      render={({ field }) => (
                        <FormItem>
                          <FormLabel className="required">
                            {t("login.form.coordinationUrl")}
                          </FormLabel>
                          <FormControl>
                            <Input
                              {...field}
                              id="coordinationUrl"
                              type="text"
                              placeholder={t(
                                "login.form.coordinationUrlDescription",
                              )}
                              autoCorrect="false"
                              autoCapitalize="false"
                              spellCheck="false"
                            />
                          </FormControl>
                          <FormMessage />
                        </FormItem>
                      )}
                    />
                  </form>
                </Form>
              )}

              {coordinationStep === "credentials" && subsonicInfo && (
                <div className="space-y-4">
                  <div className="rounded-md border border-input p-3 space-y-2">
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-medium">
                        {t("login.form.discoveredSubsonicUrl")}
                      </span>
                      <div className="flex items-center gap-2">
                        <Badge
                          variant={
                            subsonicInfo.reverseProxyEnabled
                              ? "default"
                              : "outline"
                          }
                        >
                          {subsonicInfo.reverseProxyEnabled
                            ? t("login.form.reverseProxyEnabled")
                            : t("login.form.reverseProxyDisabled")}
                        </Badge>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => {
                            setCoordinationStep("url");
                            setSubsonicInfo(null);
                          }}
                        >
                          <ArrowLeft className="h-4 w-4 mr-1" />
                          {t("login.form.back")}
                        </Button>
                      </div>
                    </div>
                    <span className="text-sm text-muted-foreground break-all">
                      {subsonicInfo.url}
                    </span>
                  </div>

                  <Form {...coordinationCredentialsForm}>
                    <form
                      id="coordination-credentials-form"
                      onSubmit={coordinationCredentialsForm.handleSubmit(
                        onSubmitCoordinationCredentials,
                      )}
                      className="space-y-2"
                    >
                      <FormField
                        control={coordinationCredentialsForm.control}
                        name="username"
                        render={({ field }) => (
                          <FormItem>
                            <FormLabel className="required">
                              {t("login.form.username")}
                            </FormLabel>
                            <FormControl>
                              <Input
                                {...field}
                                value={field.value ?? ""}
                                id="coordination-username"
                                type="text"
                                placeholder={t(
                                  "login.form.usernamePlaceholder",
                                )}
                                autoCorrect="false"
                                autoCapitalize="false"
                                spellCheck="false"
                              />
                            </FormControl>
                            <FormMessage />
                          </FormItem>
                        )}
                      />

                      <FormField
                        control={coordinationCredentialsForm.control}
                        name="password"
                        render={({ field }) => (
                          <FormItem>
                            <FormLabel className="required">
                              {t("login.form.password")}
                            </FormLabel>
                            <FormControl>
                              <Password
                                {...field}
                                value={field.value ?? ""}
                              />
                            </FormControl>
                            <FormMessage />
                          </FormItem>
                        )}
                      />
                    </form>
                  </Form>
                </div>
              )}
            </TabsContent>
          </CardContent>

          <CardFooter className="flex">
            {connectionMode === "direct" ? (
              <Button
                type="submit"
                form="direct-form"
                className="w-full"
                disabled={loading}
              >
                {loading ? (
                  <>
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    {t("login.form.connecting")}
                  </>
                ) : (
                  <>{t("login.form.connect")}</>
                )}
              </Button>
            ) : coordinationStep === "url" ? (
              <Button
                type="submit"
                form="coordination-url-form"
                className="w-full"
                disabled={fetchingInfo}
              >
                {fetchingInfo ? (
                  <>
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    {t("login.form.fetchingServerInfo")}
                  </>
                ) : (
                  <>{t("login.form.next")}</>
                )}
              </Button>
            ) : (
              <Button
                type="submit"
                form="coordination-credentials-form"
                className="w-full"
                disabled={loading}
              >
                {loading ? (
                  <>
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    {t("login.form.connecting")}
                  </>
                ) : (
                  <>{t("login.form.connect")}</>
                )}
              </Button>
            )}
          </CardFooter>
        </Tabs>
      </Card>
      <Dialog
        open={serverIsIncompatible}
        onOpenChange={(state) => {
          setServerIsIncompatible(state);
        }}
      >
        <DialogContent className="max-w-[500px]">
          <DialogHeader>
            <DialogTitle>{t("server.incompatible.title")}</DialogTitle>
          </DialogHeader>
          <p>{t("server.incompatible.description")}</p>
          <DialogFooter>
            <Button
              onClick={directForm.handleSubmit((data) =>
                onSubmitDirect(data, true),
              )}
            >
              {t("server.incompatible.skip")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}