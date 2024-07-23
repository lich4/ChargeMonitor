var lang_data = null;
$.ajax({
    url : "lang.json",
    type : "get",
    async: false,
    dataType: "json",
    success: function(res) {
        lang_data = res;
    }
});

const i18n = new VueI18n({
    locale: get_local_lang(),
    messages: lang_data,
})

const App = {
    el: "#app",
    i18n,
    data: function () {
        return {
            title: "ChargeMonitor",
            loading: false,
            daemon_alive: false,
            enable: false,
            ver: "?",
            update_freq: 1,
            dark: get_local_val("conf", "dark", false),
            lang: get_local_val("conf", "lang", "en"),
            sysver: "",
            devmodel: "",
            floatwnd: false,
            floatwnd_auto: false,
            mode: "charge_on_plug",
            msg_list: [],
            bat_info: {},
            adaptor_info: {},
            charge_below: 20,
            charge_above: 80,
            enable_temp: false,
            temp_mode: 0,
            temp_unit: null,
            charge_temp_above: 35,
            charge_temp_below: 20,
            temp_above_min: 20,
            temp_above_max: 50,
            temp_below_min: 10,
            temp_below_max: 40,
            acc_charge: false,
            acc_charge_airmode: true,
            acc_charge_wifi: false,
            acc_charge_blue: false,
            acc_charge_bright: false,
            acc_charge_lpm: true,
            action: "",
            enable_adv: false, 
            adv_prefer_smart: false,
            adv_predictive_inhibit_charge: false,
            adv_disable_inflow: false,
            adv_thermal_avail: true,
            adv_limit_inflow: false,
            adv_limit_inflow_mode: "",
            adv_def_thermal_mode: "",
            thermal_simulate_mode: "",
            ppm_simulate_mode: "",
            sys_boot: 0,
            serv_boot: 0,
            use_smart: false,
            count_msg: "",
            timer: null,
            freqs: null,
            modes: null,
            actions: null,
            cuffmods: null,
            marks_perc: range(0, 110, 10).reduce((m, o)=>{m[o] = o + "%"; return m;}, {}),
            marks_temp: null,
            conf: null,
            errc: 0,
        }
    },
    methods: {
        block_ui: function (flag) {
            this.loading = flag;
        },
        ipc_send_wrapper: function(req) {
            var that = this;
            ipc_send(req, status => {
                if (!status) {
                    that.errc += 1;
                    var max_hint = (that.update_freq <= 1) ? 10 : 1;
                    if (that.errc > max_hint) {
                        that.msg_list.push({ // 避免切窗口错误
                            "id": get_id(), 
                            "title": that.$t("conn_daemon_error"), 
                            "type": "error",
                            "time": 3000,
                        });
                        that.errc = 0;
                    }
                } else {
                    that.errc = 0;
                }
                that.daemon_alive = status;
            });
        },
        get_bat_info_cb: function(jdata) {
            this.daemon_alive = true;
            if (jdata.status == 0) {
                this.bat_info = jdata.data;
                this.adaptor_info = jdata.data.AdapterDetails;
            } else {
                this.msg_list.push({
                    "id": get_id(), 
                    "title": this.$t("fail") + ": " + jdata.status, 
                    "type": "error",
                    "time": 3000,
                });
            }
        },
        get_bat_info: function() {
            this.ipc_send_wrapper({
                api: "get_bat_info",
                callback: "window.app.get_bat_info_cb",
            });
        },
        get_health: function(item) {
            return (item["NominalChargeCapacity"] / item["DesignCapacity"] * 100).toFixed(2);
        },
        get_hardware_capacity: function() {
            var v = (this.bat_info.AppleRawCurrentCapacity / this.bat_info.NominalChargeCapacity * 100).toFixed(2);
            return v + "%";
        },
        get_capacity: function() {
            var v = (this.bat_info.CurrentCapacity / this.bat_info.NominalChargeCapacity * 100).toFixed(2);
            return v;
        },
        get_adaptor_desc: function() {
            var s = "";
            if (this.adaptor_info.Description) {
                s += "[" + this.adaptor_info.Description + "] ";
            }
            if (this.adaptor_info.Manufacturer) {
                s += "[" + this.adaptor_info.Manufacturer + " ";
            }
            if (this.adaptor_info.Name) {
                s += this.adaptor_info.Name + " ";
            }
            return s;
        },
        get_adaptor_desc: function() {
            return this.$t(this.adaptor_info.Description) + "(" + this.adaptor_info.Description + ")";
        },
        get_devmodel_desc: function() {
            return this.devmodel;
        },
        get_temp_desc: function() {
            var centigrade = this.bat_info.Temperature / 100;
            if (this.temp_mode == 0) {
                return centigrade.toFixed(1) + "°C";
            } else if (this.temp_mode == 1) {
                return t_c_to_f(centigrade).toFixed(1) + "°F";
            }
        },
        update_temp_unit: function(update_val) {
            if (this.temp_mode == 0) { // 华氏转摄氏
                this.temp_unit = "°C";
            } else if (this.temp_mode == 1) { // 摄氏转华氏
                this.temp_unit = "°F";
            }
        },
        switch_temp_unit: function() {
            this.temp_mode = (this.temp_mode + 1) % 2;
            set_local_val("conf", "temp_mode", this.temp_mode);
            this.update_temp_unit(true);
            this.ipc_send_wrapper({
                api: "set_conf",
                key: "temp_mode",
                val: this.temp_mode,
                vals: [this.charge_temp_below, this.charge_temp_above],
            });
        },
        get_conf_cb: function(jdata) {
            var that = this;
            for (var k in jdata.data) {
                this[k] = jdata.data[k];
            }
            this.conf = jdata.data;
            if (this.lang && this.lang != get_local_lang()) {
                i18n.locale = this.lang;
                set_local_val("conf", "lang", this.lang);
                this.reload_locale();
            }
            if (this.old_temp_mode == null) {
                this.update_temp_unit(false);
                this.old_temp_mode = this.temp_mode;
                set_local_val("conf", "temp_mode", this.temp_mode);
            }
            if (this.timer == null) {
                this.get_bat_info();
                if (window.test) {
                } else {
                    this.timer = setInterval(() => {
                        that.get_bat_info();
                        that.get_conf();
                    }, this.update_freq * 1000);
                }
            }
        },
        get_conf: function() {
            this.ipc_send_wrapper({
                api: "get_conf",
                callback: "window.app.get_conf_cb",
            });
        },
        change_lang: function() {
            var v = i18n.locale;
            set_local_val("conf", "lang", v);
            this.reload_locale();
            this.ipc_send_wrapper({
                api: "set_conf",
                key: "lang",
                val: v,
            });
        },
        switch_dark: function(flag) {
            this.dark = flag;
            set_local_val("conf", "dark", this.dark);
            if (flag) {
                $("body").attr("class", "night");
            } else {
                $("body").removeAttr("class", "night");
            }
        },
        reload_locale: function() {
        },
    },
    directives: {
        timeout: {
            bind(el, binding, vnode) {
                var that = vnode.context.$root;
                var time = binding.value;
                var id = el.attributes.bind_data.value;
                setTimeout(() => {
                    var index = that.msg_list.findIndex(e => e.id == id);
                    if (index > -1) {
                        that.msg_list.splice(index, 1);
                    }
                }, time);
            }
        }
    },
    mounted: function () {
        this.reload_locale();
        this.get_conf();      
    }
};

window.addEventListener("load", function () {
    window.app = new Vue(App);
    $(".noclick").click(() => {
        return false;
    });
})

