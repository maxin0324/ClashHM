export class Constants {
  static readonly APP_NAME: string = 'ClashHM';
  static readonly CONFIG_DIR: string = 'configs';
  static readonly DEFAULT_CONFIG_FILE: string = 'config.yaml';
  static readonly SUBSCRIPTIONS_KEY: string = 'subscriptions';
  static readonly SETTINGS_KEY: string = 'app_settings';
  static readonly ACTIVE_SUB_KEY: string = 'active_subscription';

  static readonly DEFAULT_MIXED_PORT: number = 7890;
  static readonly DEFAULT_SOCKS_PORT: number = 7891;
  static readonly DEFAULT_HTTP_PORT: number = 7892;
  static readonly CLASH_API_PORT: number = 9090;
  static readonly CLASH_API_SECRET: string = '';

  static readonly LATENCY_TEST_URL: string = 'https://www.gstatic.com/generate_204';
  static readonly LATENCY_TEST_TIMEOUT: number = 5000;
  static readonly TRAFFIC_POLL_INTERVAL: number = 1000;

  static readonly LATENCY_GOOD: number = 200;
  static readonly LATENCY_MEDIUM: number = 500;
  static readonly LATENCY_BAD: number = 1000;
}
