#!py

import logging
import sys
from time import time
from os.path import getsize

allowed_functions = ["is_enabled", "zeek", "fleet_image"]
states_to_apply = []

FLEET_CONTAINER = "so-elastic-fleet"
FLEET_IMAGE_ID = (
    "sha256:c786ed0c4c389d7a3074ebeb86b33c7319ae9dbac22be8ed106fd836688694b6"
)
FLEET_IMAGE_TAG = "so-socdeploy:5000/security-onion-solutions/so-elastic-agent:3.3.0"
FLEET_IMAGE_DIGEST_REF = "so-socdeploy:5000/security-onion-solutions/so-elastic-agent@sha256:29f5e64d97fd334bb7963d76449aa2940472d51110fd22200b1adea7eb16bff2"
FLEET_STATE = "elasticfleet.enabled"


def apply_states(states=""):

    calling_func = sys._getframe().f_back.f_code.co_name
    logging.debug("healthcheck_module: apply_states function caller: %s" % calling_func)

    if not states:
        states = ",".join(states_to_apply)

    if states:
        logging.info("healthcheck_module: apply_states states: %s" % str(states))
        __salt__["state.apply"](states)


def docker_stop(container):

    try:
        stopdocker = __salt__["docker.rm"](container, "stop=True")
    except Exception as e:
        logging.error("healthcheck_module: %s" % e)


def is_enabled():

    if __salt__["pillar.get"]("healthcheck:enabled", "False"):
        retval = True
    else:
        retval = False

    return retval


def run(checks=""):

    retval = []
    calling_func = sys._getframe().f_back.f_code.co_name
    logging.debug("healthcheck_module: run function caller: %s" % calling_func)

    if checks:
        checks = checks.split(",")
    else:
        checks = __salt__["pillar.get"]("healthcheck:checks", {})

    logging.debug("healthcheck_module: run checks to be run: %s" % str(checks))
    for check in checks:
        if check in allowed_functions:
            retval.append(check)
            check = getattr(sys.modules[__name__], check)
            check()
        else:
            logging.warning("healthcheck_module: attempted to run function %s" % check)

    # If you want to apply states at the end of the run,
    # be sure to append the state name to states_to_apply[]
    apply_states()

    return retval


def send_event(tag, eventdata):
    __salt__["event.send"](tag, eventdata[0])


def fleet_image():

    calling_func = sys._getframe().f_back.f_code.co_name
    logging.debug("healthcheck_module: fleet_image function caller: %s" % calling_func)
    retval = []

    expected_id = __salt__["pillar.get"](
        "healthcheck:fleet_image:expected_id", FLEET_IMAGE_ID
    )
    heal = __salt__["pillar.get"]("healthcheck:fleet_image:heal", True)

    try:
        container = __salt__["docker.inspect_container"](FLEET_CONTAINER)
    except Exception as e:
        logging.error("healthcheck_module: fleet_image inspect failed: %s" % e)
        retval.append({"fleet_image": "inspect_failed"})
        send_event("so/healthcheck/fleet_image", retval)
        return retval

    image_id = container.get("Image", "")
    image_name = container.get("Config", {}).get("Image", "")

    if image_id == expected_id:
        retval.append({"fleet_image": "ok", "image": image_name})
        send_event("so/healthcheck/fleet_image", retval)
        return retval

    logging.warning(
        "healthcheck_module: fleet_image mismatch: %s (%s), expected %s"
        % (image_name, image_id, expected_id)
    )
    retval.append(
        {
            "fleet_image": "mismatch",
            "image": image_name,
            "image_id": image_id,
            "expected": expected_id,
        }
    )

    if heal:
        try:
            __salt__["docker.pull"](FLEET_IMAGE_DIGEST_REF)
            __salt__["docker.tag"](FLEET_IMAGE_DIGEST_REF, FLEET_IMAGE_TAG)
            docker_stop(FLEET_CONTAINER)
            states_to_apply.append(FLEET_STATE)
            retval.append({"fleet_image": "healing"})
        except Exception as e:
            logging.error("healthcheck_module: fleet_image heal failed: %s" % e)
            retval.append({"fleet_image": "heal_failed"})

    send_event("so/healthcheck/fleet_image", retval)
    return retval


def zeek():

    calling_func = sys._getframe().f_back.f_code.co_name
    logging.debug("healthcheck_module: zeek function caller: %s" % calling_func)
    retval = []

    retcode = __salt__["zeekctl.status"](verbose=False)
    logging.debug("healthcheck_module: zeekctl.status retcode: %i" % retcode)
    if retcode:
        zeek_restart = 1
        if calling_func != "beacon":
            docker_stop("so-zeek")
            states_to_apply.append("zeek")
    else:
        zeek_restart = 0

    # __salt__['telegraf.send']('healthcheck zeek_restart=%i' % zeek_restart)
    # write out to file in /nsm/zeek/logs/ for telegraf to read for zeek restart
    try:
        if getsize("/nsm/zeek/logs/zeek_restart.log") >= 1000000:
            openmethod = "w"
        else:
            openmethod = "a"
    except FileNotFoundError:
        openmethod = "a"

    influxtime = int(time() * 1000000000)
    with open("/nsm/zeek/logs/zeek_restart.log", openmethod) as f:
        f.write("healthcheck zeek_restart=%i %i\n" % (zeek_restart, influxtime))

    if calling_func == "execute" and zeek_restart:
        apply_states()

    retval.append({"zeek_restart": zeek_restart})

    send_event("so/healthcheck/zeek", retval)
    return retval
