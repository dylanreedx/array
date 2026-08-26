import styles from './ProviderMark.module.css';

interface ProviderMarkProps {
  provider: string;
  className?: string;
}

function providerKey(provider: string) {
  const value = provider.toLowerCase();
  if (value.includes('codex') || value.includes('openai')) return 'openai';
  if (value.includes('claude') || value.includes('anthropic')) return 'anthropic';
  return 'pi';
}

export function ProviderMark({ provider, className = '' }: ProviderMarkProps) {
  const key = providerKey(provider);
  return <span className={`${styles.mark} ${styles[key]} ${className}`} data-provider-mark={key} title={provider} aria-label={`${provider} provider`} role="img" />;
}
