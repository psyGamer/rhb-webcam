#!/bin/bash

cd $(dirname $0)/..
REPO_DIR=$(pwd)

sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-server.service | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-server.service

sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-filisur.service    | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-filisur.service
sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-landquart.service  | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-landquart.service
sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-brusio.service     | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-brusio.service
sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-livestream.service | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-livestream.service
sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-ilanz.service      | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-ilanz.service
sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-miralago.service   | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-miralago.service

sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-archive-day.service                  | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-archive-day.service
sed -e "s\\##REPO_DIR##\\$REPO_DIR\\g" systemd/rhb-fetch-locomotive-allocations.service | sed -e "s\\##USER##\\$USER\\g" | sudo tee /etc/systemd/system/rhb-fetch-locomotive-allocations.service

sudo cp systemd/rhb-daily.service /etc/systemd/system/rhb-daily.service
sudo cp systemd/rhb-daily.timer /etc/systemd/system/rhb-daily.timer

sudo systemctl daemon-reload

sudo systemctl enable rhb-filisur
sudo systemctl enable rhb-landquart
sudo systemctl enable rhb-brusio
sudo systemctl enable rhb-livestream
sudo systemctl enable rhb-ilanz
sudo systemctl enable rhb-miralago

sudo systemctl enable rhb-daily.timer

sudo systemctl restart rhb-filisur
sudo systemctl restart rhb-landquart
sudo systemctl restart rhb-brusio
sudo systemctl restart rhb-livestream
sudo systemctl restart rhb-ilanz
sudo systemctl restart rhb-miralago