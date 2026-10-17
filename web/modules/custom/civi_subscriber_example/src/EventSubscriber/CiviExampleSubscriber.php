<?php

namespace Drupal\civi_subscriber_example\EventSubscriber;

use Civi\API\Event\PrepareEvent;
use Civi\Core\Event\GenericHookEvent;
use Psr\Log\LoggerInterface;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;

/**
 * Listens to CiviCRM Symfony events from Drupal.
 *
 * This is an ordinary Symfony EventSubscriberInterface. Because its service is
 * tagged "civicrm.event_subscriber" (see civi_subscriber_example.services.yml),
 * the civicrm module attaches it to \Civi::dispatcher() once CiviCRM boots, so
 * the events below are the names CiviCRM dispatches — not Drupal events.
 */
class CiviExampleSubscriber implements EventSubscriberInterface {

  /**
   * The logger channel, injected via dependency injection.
   *
   * @var \Psr\Log\LoggerInterface
   */
  protected LoggerInterface $logger;

  /**
   * Constructs the subscriber.
   *
   * @param \Psr\Log\LoggerInterface $logger
   *   The "civi_subscriber_example" logger channel.
   */
  public function __construct(LoggerInterface $logger) {
    $this->logger = $logger;
  }

  /**
   * {@inheritdoc}
   *
   * Keys are CiviCRM event names; values are methods on this class.
   */
  public static function getSubscribedEvents(): array {
    return [
      'civi.api.prepare' => 'onApiPrepare',
      'hook_civicrm_buildForm' => 'onBuildForm',
    ];
  }

  /**
   * Reacts to the "civi.api.prepare" event (fired before each API request).
   *
   * @param \Civi\API\Event\PrepareEvent $event
   *   The API prepare event.
   */
  public function onApiPrepare(PrepareEvent $event): void {
    // Payload shape can vary (APIv3 array vs APIv4 action object), so read it
    // defensively for the demo.
    try {
      $signature = $event->getApiRequestSig();
    }
    catch (\Throwable $e) {
      $signature = '(unknown)';
    }

    $this->logger->notice('CiviCRM event "civi.api.prepare" fired for API request @sig.', [
      '@sig' => $signature,
    ]);
  }

  /**
   * Reacts to the "hook_civicrm_buildForm" event (fired as a CiviCRM form builds).
   *
   * @param \Civi\Core\Event\GenericHookEvent $event
   *   The hook event. Hook parameters are exposed as named properties, matching
   *   the hook signature hook_civicrm_buildForm($formName, &$form).
   */
  public function onBuildForm(GenericHookEvent $event): void {
    $this->logger->notice('CiviCRM event "hook_civicrm_buildForm" fired for form @form.', [
      '@form' => $event->formName,
    ]);
  }

}
