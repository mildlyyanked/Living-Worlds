/// Settings: LLM mode (offline / dev direct key / Supabase proxy §7),
/// model pin, context budget, debug panel toggle (§9).
library;

import 'package:flutter/material.dart';

import '../app_services.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Narrator (LLM)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            RadioGroup<LlmMode>(
              groupValue: settings.llmMode,
              onChanged: (v) => settings.update((s) => s.llmMode = v!),
              child: const Column(
                children: [
                  RadioListTile<LlmMode>(
                    title: Text('Offline narrator'),
                    subtitle: Text(
                      'No network. Deterministic canned prose — '
                      'engine still runs everything.',
                    ),
                    value: LlmMode.offline,
                  ),
                  RadioListTile<LlmMode>(
                    title: Text('OpenRouter (dev key on device)'),
                    subtitle: Text(
                      'Dev-only direct path — the key lives on '
                      'this device (§7).',
                    ),
                    value: LlmMode.openRouterDirect,
                  ),
                  RadioListTile<LlmMode>(
                    title: Text('Supabase key vault (production)'),
                    subtitle: Text(
                      'Completions proxied; keys never touch the app.',
                    ),
                    value: LlmMode.supabaseProxy,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (settings.llmMode == LlmMode.openRouterDirect)
              TextFormField(
                initialValue: settings.openRouterKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'OpenRouter API key',
                ),
                onChanged: (v) => settings.update((s) => s.openRouterKey = v),
              ),
            if (settings.llmMode == LlmMode.supabaseProxy) ...[
              TextFormField(
                initialValue: settings.supabaseUrl,
                decoration: const InputDecoration(
                  labelText: 'Supabase URL',
                  hintText: 'https://xyz.supabase.co',
                ),
                onChanged: (v) => settings.update((s) => s.supabaseUrl = v),
              ),
              TextFormField(
                initialValue: settings.supabaseAnonKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Supabase anon key',
                ),
                onChanged: (v) => settings.update((s) => s.supabaseAnonKey = v),
              ),
            ],
            if (settings.llmMode != LlmMode.offline)
              TextFormField(
                initialValue: settings.model,
                decoration: const InputDecoration(
                  labelText: 'Model (pin a tool-calling-reliable one, §14)',
                ),
                onChanged: (v) => settings.update((s) => s.model = v),
              ),
            const Divider(height: 32),
            SwitchListTile(
              key: const Key('debug-toggle'),
              title: const Text('Debug panel'),
              subtitle: const Text(
                'Show the full turn transaction: raw LLM '
                'output, per-delta decisions, death eval, context tokens.',
              ),
              value: settings.debugPanel,
              onChanged: (v) => settings.update((s) => s.debugPanel = v),
            ),
            ListTile(
              title: const Text('Context budget (tokens)'),
              subtitle: Slider(
                min: 1000,
                max: 16000,
                divisions: 15,
                value: settings.contextBudgetTokens.toDouble(),
                label: '${settings.contextBudgetTokens}',
                onChanged: (v) =>
                    settings.update((s) => s.contextBudgetTokens = v.round()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
